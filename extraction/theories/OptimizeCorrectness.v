From ConCert.Extraction Require Import Aux.
From ConCert.Extraction Require Import ExAst.
From ConCert.Extraction Require Import ExTyping.
From ConCert.Extraction Require Import Optimize.
From ConCert.Extraction Require Import WcbvEvalAux.
From Coq Require Import Arith.
From Coq Require Import Bool.
From Coq Require Import String.
From Coq Require Import List.
From Coq Require Import Psatz.
From Equations Require Import Equations.
From MetaCoq.Erasure Require Import EAstUtils.
From MetaCoq.Erasure Require Import ECSubst.
From MetaCoq.Erasure Require Import EInduction.
From MetaCoq.Erasure Require Import ELiftSubst.
From MetaCoq.Erasure Require Import EWcbvEval.
From MetaCoq.Template Require Import utils.

Import ListNotations.

Import EAstUtils.
Import Erasure.
Import ExAst.

(* We have our own environment which is different from MetaCoq's erased environment
   (it includes more information and a different treatment of types).
   To reconcile this, we map our environments to theirs, but the treatment of types
   remains different. However, MetaCoq does not actually use information about types
   for anything during evaluation, so we just filter them out. This is justified
   by the following lemmas. *)
Definition is_constant (decl : EAst.global_decl) : bool :=
  match decl with
  | EAst.ConstantDecl _ => true
  | _ => false
  end.

Definition only_constants (Σ : EAst.global_context) : EAst.global_context :=
  filter (is_constant ∘ snd) Σ.

Lemma declared_constant_only_constants Σ kn decl :
  ETyping.declared_constant Σ kn decl ->
  ETyping.declared_constant (only_constants Σ) kn decl.
Proof.
  unfold ETyping.declared_constant.
  intros lookup_decl.
  induction Σ; [easy|].
  destruct a as (kn' & decl').
  cbn in *.
  destruct (is_constant decl') eqn:isconst.
  - cbn in *.
    destruct (kername_eq_dec _ _) as [<-|?]; easy.
  - apply IHΣ.
    destruct (kername_eq_dec _ _).
    + inversion lookup_decl; subst; easy.
    + auto.
Qed.

Lemma eval_only_constants Σ s t :
  Σ ⊢ s ▷ t ->
  only_constants Σ ⊢ s ▷ t.
Proof.
  induction 1 using eval_evals_ind;
    eauto using eval, declared_constant_only_constants.
Qed.

Definition trans_cst (cst : constant_body) : EAst.constant_body :=
  {| EAst.cst_body := cst_body cst |}.

Definition trans (Σ : global_env) : EAst.global_context :=
  let map_decl kn (decl : global_decl) : list (kername * EAst.global_decl) :=
      match decl with
      | ConstantDecl cst => [(kn, EAst.ConstantDecl (trans_cst cst))]
      | InductiveDecl _ => []
      end in
  flat_map (fun '(kn, decl) => map_decl kn decl) Σ.

Lemma declared_constant_trans Σ kn cst :
  declared_constant Σ kn cst ->
  ETyping.declared_constant (trans Σ) kn (trans_cst cst).
Proof.
  unfold ETyping.declared_constant, declared_constant in *.
  induction Σ; [easy|]; intros lookup.
  cbn in *.
  destruct a as (kn' & []).
  - cbn in *.
    unfold eq_kername in *.
    destruct (kername_eq_dec kn kn') as [<-|].
    + now inversion lookup; subst; clear lookup.
    + now apply IHΣ.
  - apply IHΣ.
    unfold eq_kername in lookup.
    now destruct (kername_eq_dec _ _).
Qed.

Section dearg_correctness.
Context (ind_masks : list (kername * mib_masks)).
Context (const_masks : list (kername * bitmask)).

Fixpoint has_use (rel : nat) (t : term) : bool :=
  match t with
  | tRel i => i =? rel
  | tEvar _ ts => fold_right orb false (map (has_use rel) ts)
  | tLambda _ body => has_use (S rel) body
  | tLetIn _ val body => has_use rel val || has_use (S rel) body
  | tApp hd arg => has_use rel hd || has_use rel arg
  | tCase _ _ brs => fold_right orb false (map (has_use rel ∘ snd) brs)
  | tProj _ t => has_use rel t
  | tFix defs _
  | tCoFix defs _ => fold_right orb false (map (has_use (rel + #|defs|) ∘ dbody) defs)
  | _ => false
  end.

Fixpoint valid_dearg_mask (mask : bitmask) (body : term) : Prop :=
  match body, mask with
  | tLetIn na val body, _ => valid_dearg_mask mask body
  | tLambda _ body, b :: mask =>
    (if b then has_use 0 body = false else True) /\ valid_dearg_mask mask body
  | _, [] => True
  | _, _ => False
  end.

Lemma dearg_cst_body_top_nil t :
  dearg_cst_body_top [] t = t.
Proof.
  induction t; auto.
  cbn.
  now rewrite IHt2.
Qed.

Lemma dearg_single_0_mask mask args t :
  Forall (eq false) mask ->
  #|args| = #|mask| ->
  dearg_single mask t args = mkApps t args.
Proof.
  intros mask_zero.
  revert args t.
  induction mask_zero.
  - destruct args; easy.
  - intros [|a args] t len_eq; [easy|].
    subst.
    cbn in *.
    now apply IHmask_zero.
Qed.

Lemma dearg_single_snoc mask b t args a :
  #|mask| = #|args| ->
  dearg_single (mask ++ [b]) t (args ++ [a]) =
  if b then
    dearg_single mask t args
  else
    tApp (dearg_single mask t args) a.
Proof.
  revert t args b a.
  induction mask as [|b mask IH]; intros t args bend aend len_eq.
  - now destruct args as [|a args]; [|easy].
  - destruct args as [|a args]; [easy|].
    cbn in *.
    destruct b.
    + now apply IH.
    + now apply IH.
Qed.

(* We use our own "properly ordered" contexts to represent the lambdas/lets
   that we debox away. Unlike the rest of MetaCoq, these contexts actually
   have the first declaration at the beginning. *)
Fixpoint subst_context (t : term) (k : nat) (Γ : context) : context :=
  match Γ with
  | [] => []
  | cd :: Γ => map_decl (csubst t k) cd :: subst_context t (S k) Γ
  end.

Definition mkLambda_or_LetIn (cd : context_decl) (t : term) : term :=
  match decl_body cd with
  | None => tLambda (decl_name cd) t
  | Some body => tLetIn (decl_name cd) body t
  end.

Definition it_mkLambda_or_LetIn (Γ : context) (u : term) : term :=
  fold_right mkLambda_or_LetIn u Γ.

Lemma subst_context_app t k Γ Γ' :
  subst_context t k (Γ ++ Γ') =
  subst_context t k Γ ++ subst_context t (length Γ + k) Γ'.
Proof.
  revert t k Γ'.
  induction Γ as [|cd Γ IH]; intros t k Γ'; [easy|].
  cbn.
  f_equal.
  now rewrite IH.
Qed.

Fixpoint decompose_body_masked (mask : bitmask) (t : term) : context * term :=
  match mask, t with
  | _, tLetIn na val body =>
    let (Γ, t) := decompose_body_masked mask body in
    (vdef na val :: Γ, t)
  | b :: mask, tLambda na body =>
    let (Γ, t) := decompose_body_masked mask body in
    (vass na :: Γ, t)
  | _, _ => ([], t)
  end.

Definition vasses (Γ : context) : context :=
  filter (fun cd => match decl_body cd with
                    | Some _ => false
                    | None => true
                    end) Γ.

Lemma vasses_app Γ Γ' :
  vasses (Γ ++ Γ') = vasses Γ ++ vasses Γ'.
Proof.
  unfold vasses.
  now rewrite filter_app.
Qed.

Ltac refold :=
  repeat
    match goal with
    | [H: context[fold_right _ ?t ?Γ] |- _] => progress (fold (it_mkLambda_or_LetIn Γ t) in * )
    | [|- context[fold_right _ ?t ?Γ]] => progress (fold (it_mkLambda_or_LetIn Γ t) in * )
    | [H: context[filter _ ?Γ] |- _] => progress (fold (vasses Γ) in * )
    | [|- context[filter _ ?Γ]] => progress (fold (vasses Γ) in * )
    end.

Lemma decompose_body_masked_spec mask Γ t t' :
  valid_dearg_mask mask t ->
  (Γ, t') = decompose_body_masked mask t ->
  #|vasses Γ| = #|mask| /\
  it_mkLambda_or_LetIn Γ t' = t.
Proof.
  revert Γ t' mask.
  induction t using term_forall_list_ind; intros Γ t' mask valid_mask eq.
  all: cbn in *.
  all: try solve [destruct mask; [|easy]; inversion eq; easy].
  - destruct mask as [|b mask]; inversion eq; subst; clear eq; [easy|].
    cbn in *.
    destruct (decompose_body_masked mask t) as (Γ' & t'') eqn:decomp_eq.
    inversion H0; subst; clear H0.
    symmetry in decomp_eq.
    cbn.
    refold.
    now destruct (IHt _ _ _ (proj2 valid_mask) decomp_eq) as (-> & ->).
  - destruct (decompose_body_masked mask t2) eqn:decomp_eq.
    symmetry in decomp_eq.
    destruct (IHt2 _ _ _ valid_mask decomp_eq).
    now destruct mask; inversion eq; subst.
Qed.

Lemma valid_dearg_mask_spec mask t :
  valid_dearg_mask mask t ->
  exists Γ inner,
    #|vasses Γ| = #|mask| /\ it_mkLambda_or_LetIn Γ inner = t.
Proof.
  intros is_valid.
  destruct (decompose_body_masked mask t) as (Γ & inner) eqn:decomp.
  exists Γ, inner.
  now apply decompose_body_masked_spec.
Qed.

Lemma subst_it_mkLambda_or_LetIn t k Γ u :
  csubst t k (it_mkLambda_or_LetIn Γ u) =
  it_mkLambda_or_LetIn (subst_context t k Γ) (csubst t (k + length Γ) u).
Proof.
  revert t k u.
  induction Γ as [|cd Γ IH]; intros t k u.
  - cbn.
    f_equal; lia.
  - cbn in *; refold.
    destruct cd as [na [val|]];
      cbn in *; refold;
      repeat (f_equal; rewrite ?IH; try lia).
Qed.

Lemma length_subst_context t k Γ :
  #|subst_context t k Γ| = #|Γ|.
Proof.
  revert t k.
  induction Γ; [easy|]; intros t k.
  cbn.
  now rewrite IHΓ.
Qed.

(* Given [Γ ⊢ t] and args for assumptions in [Γ], return Γ' ⊢ t' by substituting
   as many args as available into Γ and t. *)
Equations? close_context_term (Γ : context) (t : term) (args : list term) : context * term
  by wf #|Γ| lt :=
close_context_term ({| decl_body := Some val |} :: Γ) t args :=
  close_context_term (subst_context val 0 Γ) (csubst val #|Γ| t) args;
close_context_term ({| decl_body := None |} :: Γ) t (a :: args) :=
  close_context_term (subst_context a 0 Γ) (csubst a #|Γ| t) args;
close_context_term Γ t args := (Γ, t).
Proof. all: now rewrite length_subst_context. Qed.

Lemma close_context_term_cons cd Γ t args :
  close_context_term (cd :: Γ) t args =
  match decl_body cd with
  | Some val => close_context_term (subst_context val 0 Γ) (csubst val #|Γ| t) args
  | None =>
    match args with
    | a :: args => close_context_term (subst_context a 0 Γ) (csubst a #|Γ| t) args
    | [] => (cd :: Γ, t)
    end
  end.
Proof.
  destruct cd, decl_body.
  - now simp close_context_term.
  - destruct args.
    + now simp close_context_term.
    + now simp close_context_term.
Qed.

Hint Rewrite close_context_term_cons : close_context_term.

Definition close_term (Γ : context) (t : term) (args : list term) : term :=
  (close_context_term Γ t args).2.

Definition close_context (Γ : context) (args : list term) : context :=
  (close_context_term Γ tBox args).1.

Lemma close_term_cons cd Γ t args :
  close_term (cd :: Γ) t args =
  match decl_body cd with
  | Some val => close_term (subst_context val 0 Γ) (csubst val #|Γ| t) args
  | None =>
    match args with
    | a :: args => close_term (subst_context a 0 Γ) (csubst a #|Γ| t) args
    | [] => t
    end
  end.
Proof.
  unfold close_term.
  simp close_context_term.
  destruct (decl_body cd); [easy|].
  destruct args; easy.
Qed.

Lemma close_term_nil_context t args :
  close_term [] t args = t.
Proof.
  unfold close_term.
  now simp close_context_term.
Qed.

Hint Rewrite close_term_cons close_term_nil_context : close_term.

(*
Lemma close_term_app Γ Γ' t args :
  close_context_term (Γ ++ Γ') t args =
  close_context Γ' (close_term Γ t args) (skipn #|vasses Γ| args).
Proof.
  induction #|Γ| as [|n IH] eqn:len_eq in Γ, Γ', t, args |- *.
  - destruct Γ; [|easy].
    now simp close_term.
  - destruct Γ as [|cd Γ]; [easy|].
    cbn in  *.
    simp close_term.
    destruct (decl_body cd).
    + rewrite subst_context_app.
      rewrite IH by (now rewrite length_subst_context).
      refold.
      specialize (IH (subst_context t0 0 Γ) (subst_context t0 (#|Γ| + 0) Γ')
                     ltac:(now rewrite length_subst_context)).
      rewrite IH.
j
*)


Fixpoint eval_lambdas Σ (t : term) (args : list term) : Prop :=
  match args with
  | [] => exists res, Σ ⊢ t ▷ res
  | a :: args =>
    exists na body,
      Σ ⊢ t ▷ tLambda na body /\
      eval_lambdas Σ (tApp (tLambda na body) a) args
  end.

Lemma eval_lambdas_tLetIn Σ na val val_res body args :
  Σ ⊢ val ▷ val_res ->
  eval_lambdas Σ (csubst val_res 0 body) args ->
  eval_lambdas Σ (tLetIn na val body) args.
Proof.
  revert na val val_res body.
  induction args; intros na val val_res body ev_val ev; cbn in *.
  - destruct ev as (res & ev).
    exists res.
    econstructor; easy.
  - destruct ev as (na_lam & lam_body & ev_lam_val & ev).
    exists na_lam, lam_body.
    split.
    + econstructor; easy.
    + easy.
Qed.

Lemma eval_lambdas_tApp_tLambda Σ na body a av args :
  Σ ⊢ a ▷ av ->
  eval_lambdas Σ (csubst av 0 body) args ->
  eval_lambdas Σ (tApp (tLambda na body) a) args.
Proof.
  revert na body a av.
  induction args; intros na body a' av ev_val ev; cbn in *.
  - destruct ev as (res & ev).
    exists res.
    econstructor.
    + now apply eval_atom.
    + easy.
    + easy.
  - destruct ev as (na_lam & body_lam & ev_lam_val & ev).
    exists na_lam, body_lam.
    split.
    + econstructor.
      * now apply eval_atom.
      * easy.
      * easy.
    + easy.
Qed.

Lemma has_use_closed k t n :
  closedn k t ->
  k <= n ->
  has_use n t = false.
Proof.
  revert k n.
  induction t using term_forall_list_ind; intros k n' clos klen;
    cbn in *; auto.
  - propify.
    destruct (Nat.eqb_spec n n'); lia.
  - induction H; [easy|].
    cbn in *.
    propify.
    easy.
  - easy.
  - propify.
    easy.
  - propify.
    easy.
  - propify.
    induction X; [easy|].
    destruct x.
    cbn in *.
    propify.
    easy.
  - easy.
  - revert k n' clos klen.
    induction H; [easy|]; intros k n' clos klen.
    destruct x.
    cbn in *.
    propify.
    split; [easy|].
    replace (n' + S #|l|) with (S n' + #|l|) by abstract lia.
    apply (IHForall (S k)); [|easy].
    now rewrite Nat.add_succ_r.
  - revert k n' clos klen.
    induction H; [easy|]; intros k n' clos klen.
    destruct x.
    cbn in *.
    propify.
    split; [easy|].
    replace (n' + S #|l|) with (S n' + #|l|) by abstract lia.
    apply (IHForall (S k)); [|easy].
    now rewrite Nat.add_succ_r.
Qed.

Lemma has_use_csubst k t u k' :
  has_use k t = false ->
  closedn k u ->
  k < k' ->
  has_use k (csubst u k' t) = false.
Proof.
  revert k u k'.
  induction t using term_forall_list_ind; intros k u k' use_eq clos kltn;
    cbn in *; auto.
  - propify.
    destruct (Nat.compare_spec k' n) as [->| |].
    + now apply has_use_closed with k.
    + cbn.
      propify.
      lia.
    + cbn.
      propify.
      lia.
  - induction H; [easy|].
    cbn in *.
    propify.
    easy.
  - propify.
    apply IHt; [easy| |easy].
    now eapply closed_upwards.
  - propify.
    split; [easy|].
    apply IHt2; [easy| |easy].
    now eapply closed_upwards.
  - propify.
    split; [easy|].
    apply IHt2; [easy| |easy].
    now eapply closed_upwards.
  - induction X; [easy|].
    destruct x.
    cbn in *.
    propify.
    easy.
  - revert k k' kltn use_eq clos.
    induction H; [easy|]; intros k k' kltn use_eq clos.
    destruct x.
    cbn in *.
    propify.
    rewrite map_length in *.
    split.
    + apply H; [easy| |easy].
      now eapply closed_upwards.
    + setoid_rewrite map_length in IHForall.
      replace (k + S #|l|) with (S k + #|l|) in * by abstract lia.
      rewrite <- Nat.add_succ_r.
      apply IHForall; [easy|easy|].
      now eapply closed_upwards.
  - revert k k' kltn use_eq clos.
    induction H; [easy|]; intros k k' kltn use_eq clos.
    destruct x.
    cbn in *.
    propify.
    rewrite map_length in *.
    split.
    + apply H; [easy| |easy].
      now eapply closed_upwards.
    + setoid_rewrite map_length in IHForall.
      replace (k + S #|l|) with (S k + #|l|) in * by abstract lia.
      rewrite <- Nat.add_succ_r.
      apply IHForall; [easy|easy|].
      now eapply closed_upwards.
Qed.

(*

Lemma closedn_subst0 s k t :
  forallb (closedn k) s -> closedn (k + #|s|) t ->
  closedn k (subst0 s t).
Proof.
  intros.
  generalize (closedn_subst s k 0 t H).
  rewrite Nat.add_0_r. eauto.
Qed.
*)


(*
  intros.
  rewrite closed_subst; auto.
  eapply closedn_subst0. simpl. erewrite closed_upwards; eauto. lia.
  simpl. now rewrite Nat.add_1_r.
Qed.
*)


Lemma valid_dearg_mask_nil t : valid_dearg_mask [] t.
Proof. induction t; easy. Qed.

Lemma valid_dearg_mask_csubst mask t u k :
  valid_dearg_mask mask t ->
  closed u ->
  valid_dearg_mask mask (csubst u k t).
Proof.
  revert mask u k.
  induction t using term_forall_list_ind; intros mask u k valid_mask clos;
    cbn in *;
    try solve [now destruct mask].
  - destruct mask; [|easy].
    apply valid_dearg_mask_nil.
  - destruct mask; [easy|].
    split.
    + destruct b; [|easy].
      now apply (has_use_csubst 0).
    + now apply IHt.
Qed.

Lemma valid_dearg_mask_app mask mask' Γ inner :
  valid_dearg_mask (mask ++ mask') (it_mkLambda_or_LetIn Γ inner) ->
  #|vasses Γ| = #|mask| ->
  valid_dearg_mask mask' inner.
Proof.
  revert mask mask' inner.
  induction Γ as [|cd Γ IH]; intros mask mask' inner len_eq valid_mask.
  - destruct mask; [|easy].
    easy.
  - cbn in *; refold.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + cbn in *.
      easy.
    + cbn in *.
      destruct mask; [now cbn in *|].
      cbn in *.
      destruct b.
      * now eapply IH.
      * easy.
Qed.

(*
Lemma eval_it_mkLambda_or_LetIn_bodies Σ Γ Γ' body body' v :
  Σ ⊢ it_mkLambda_or_LetIn (Γ ++ Γ') body ▷ v ->
  Σ ⊢ it_mkLambda_or_LetIn Γ' (close_term_aux body' ▷ v
*)

(*
Lemma close_term_aux_csubst_let Σ Γ na lv inner args v :
  #|args| = #|vasses Γ| ->
  Σ ⊢ mkApps (it_mkLambda_or_LetIn Γ (tLetIn na lv inner)) args ▷ v ->
  Σ ⊢ close_term_aux Γ (csubst lv 0 inner) (List.rev args) ▷ v.
Proof.
  revert na lv inner args v.
  induction Γ as [|cd Γ IH] using List.rev_ind; intros na lv inner args v ev len_eq.
  - destruct args; [|easy].
    cbn in *.
    admit.
  - rewrite vasses_app, app_length, it_mkLambda_or_LetIn_app, close_term_aux_app in *
      by (rewrite List.rev_length; lia).
    cbn in *.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + cbn in *.
*)

(*
Lemma eval_mkApps_it_mkLambda_or_LetIn Σ Γ inner args t :
  #|args| = #|vasses Γ| ->
  Σ ⊢ mkApps (it_mkLambda_or_LetIn Γ inner) args ▷ t ->
  Σ ⊢ close_term_aux Γ inner (List.rev args) ▷ t.
Proof.
  revert inner args t.
  induction Γ as [|cd Γ IH]; intros inner args t len_eq ev.
  - now destruct args.
  - cbn in *; refold.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    +
    + destruct args as [|a args _] using List.rev_ind; cbn in *; [easy|].
      rewrite List.rev_app_distr, mkApps_app in *.
      cbn in *.
      Lemma close_term_aux_csubst Σ :
        Σ ⊢
        Σ ⊢ close_term_aux Γ (csubst a 0 inner) (List.rev args) ▷ t
      rewrite mkApps_app in ev.
      cbn in *
      rewrite skipn_all_app_eq by (rewrite List.rev_length; lia).
    rewrite vasses_app, app_length, it_mkLambda_or_LetIn_app, close_term_aux_app in *
      by (rewrite List.rev_length; lia).
    cbn in *; refold.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + admit.
    + destruct args as [|a args]; cbn in *; [easy|].
      rewrite skipn_all_app_eq by (rewrite List.rev_length; lia).
*)

(*
Section foo.
From Coq Require Import String.
From MetaCoq.Erasure Require Import EPretty.
Open Scope string.

Definition Γ := [vass (nNamed "a")].
Definition Γ' := [vass (nNamed "d"); vass (nNamed "c")].
Definition args := [tVar "a"].
Definition args' := [tVar "c"; tVar "d"].
Definition inner := tRel 0.
Open Scope list.
Compute print_term [] [] false false
        (mkApps (it_mkLambda_or_LetIn (Γ' ++ Γ) inner) (args ++ args')).
Compute print_term [] [] false false
        (mkApps (it_mkLambda_or_LetIn Γ (close_term Γ' inner args')) args).
Compute print_term [] [] false false
        (close_term (Γ' ++ Γ) inner (args ++ args')).
End foo.
*)

Lemma vasses_subst_context t k Γ :
  vasses (subst_context t k Γ) = vasses Γ.
Proof.
  revert t k.
  induction Γ as [|cd Γ IH]; [easy|]; intros t k.
  cbn in *.
  unfold map_decl.
  destruct cd.
  cbn in *.
  destruct decl_body; cbn.
  - easy.
  - f_equal.
    easy.
Qed.

Lemma eval_mkApps_it_mkLambda_or_LetIn Σ Γ inner args t :
  #|args| = #|vasses Γ| ->
  Σ ⊢ mkApps (it_mkLambda_or_LetIn Γ inner) args ▷ t ->
  Σ ⊢ close_term Γ inner args ▷ t.
Proof.
  intros len_eq ev.
  unfold close_term.
  funelim (close_context_term Γ inner args);
    simp close_context_term;
    cbn in *.
  - now destruct args.
  - refold.
    apply H; try easy.
    + now rewrite vasses_subst_context.
    + apply eval_mkApps_head in ev as ev_hd.
      destruct ev_hd as (hdv & ev_hd).
      eapply eval_mkApps_heads.
      * exact ev_hd.
      * rewrite <- subst_it_mkLambda_or_LetIn.
        apply eval_tLetIn_inv in ev_hd as (? & ? & ?).
        now eapply eval_csubst_commute.
      * easy.
  - congruence.
  - refold.
    apply H.
    + now rewrite vasses_subst_context.
    + apply eval_mkApps_head in ev as ev_hd.
      destruct ev_hd as (hdv & ev_hd).
      eapply eval_mkApps_heads.
      * exact ev_hd.
      * rewrite <- subst_it_mkLambda_or_LetIn.
        apply eval_tApp_tLambda_inv in ev_hd as (? & ? & ?).
        now eapply eval_csubst_commute.
      * easy.
Qed.

Lemma eval_mkApps_it_mkLambda_or_LetIn Σ Γ Γ' inner args args' t :
  #|args| = #|vasses Γ| ->
  #|args'| = #|vasses Γ'| ->
  Σ ⊢ mkApps (it_mkLambda_or_LetIn Γ (close_term Γ' inner args')) args ▷ t ->
  Σ ⊢ close_term (Γ' ++ Γ) inner (args ++ args') ▷ t.
Proof.
  revert Γ' inner args args' t.
  induction Γ as [|cd Γ IH]; intros Γ' inner args args' t len_eq len_eq' ev.
  - destruct args; [|easy].
    now rewrite app_nil_r.
  - cbn in *; refold.
    unfold close_term.
    rewrite List.rev_app_distr.
    cbn.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + admit.
    + destruct args as [|a args _] using List.rev_ind; [easy|].
      rewrite !List.rev_app_distr.
      rewrite close_term_aux_app; cycle 1.
      { rewrite !app_length, !List.rev_length in *.
        now cbn in *. }
      cbn in *.
      rewrite decl_eq.
      rewrite <- len_eq'.
      rewrite <- List.rev_length.
      rewrite skipn_all_app.
      rewrite mkApps_app in ev.
      rewrite !app_length in *.
      cbn in *.
      specialize (IH Γ' inner args args' t ltac:(lia) len_eq').
      apply
      cbn.
    rewrite close_term_aux_app; cycle 1.
    { rewrite List.rev_length, app_length.
      lia. }
    cbn.
    destruct (decl_body cd) eqn:decl_eq.
    +
      rewrite List.rev_app_distr.
      rewrite <- len_eq'.
      rewrite <- List.rev_length.
      rewrite skipn_all_app.
      specialize (IH (Γ' ++ [cd]) inner args args' t len_eq).
      cbn in IH; refold.
      rewrite vasses_app, app_length in IH.
      cbn in IH.
      rewrite decl_eq in IH.
      specialize (IH ltac:(cbn; easy)).
      rewrite close_term_aux_app in IH.

    rewrite <- app_tip_assoc.
    rewrite app
    apply IH.
    destruct (decl_body cd) eqn:decl_eq.
    + apply IH; [easy|easy|].
    rewrite vasses_app, app_length, it_mkLambda_or_LetIn_app, close_term_aux_app in *;
      cycle 1.
    { rewrite List.rev_length, app_length.
      cbn in *.
      lia. }
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + replace (List.rev (args ++ args')) with (skipn #|vasses [cd]| (List.rev (args ++ args')));
        cycle 1.
      { cbn.
        now rewrite decl_eq. }
      replace (csubst t0 0 inner) with (close_term_aux [cd] inner (List.rev (args ++ args')));
        cycle 1.
      { cbn.
        now rewrite decl_eq. }
      rewrite <- close_term_aux_app by (now cbn; rewrite decl_eq; cbn).
    cbn in *.
    rewrite app_nil_r in *.
    cbn in *.
  - rewrite vasses_app, app_length, app_assoc in *.
    rewrite it_mkLambda_or_LetIn_app, close_term_aux_app in *
      by (rewrite List.rev_length; abstract lia).
    cbn in *.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + admit.
    + destruct args as [|a args]; cbn in *; [easy|].
      rewrite skipn_all_app_eq by (rewrite List.rev_length; now lia).
      rewrite close_term_aux_app.
    cbn in *; refold.
    rewrite <- app_tip_assoc in ev.
    rewrite it_mkLambda_or_LetIn_app in ev.
    rewrite app_assoc in ev.
    rewrite vasses_app, app_length in *.
    rewrite close_term_aux_app by (rewrite List.rev_length; abstract lia).

  revert Γ' inner args args' t.
  induction Γ as [|cd Γ IH] using List.rev_ind; intros Γ' inner args args' t len_eq len_eq' ev.
  - destruct args; [|easy].
    now rewrite app_nil_r in *.
  - rewrite vasses_app, app_length, app_assoc in *.
    rewrite it_mkLambda_or_LetIn_app, close_term_aux_app in *
      by (rewrite List.rev_length; abstract lia).
    cbn in *.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + admit.
    + destruct args as [|a args]; cbn in *; [easy|].
      rewrite skipn_all_app_eq by (rewrite List.rev_length; now lia).
      rewrite close_term_aux_app.
    cbn in *; refold.
    rewrite <- app_tip_assoc in ev.
    rewrite it_mkLambda_or_LetIn_app in ev.
    rewrite app_assoc in ev.
    rewrite vasses_app, app_length in *.
    rewrite close_term_aux_app by (rewrite List.rev_length; abstract lia).
    rewrite app_assoc, it_mkLambda_or_LetIn_app in ev.
    cbn in *.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + cbn in *.
      specialize (IH (Γ' ++ [cd]) inner args args' t ltac:(easy)).
      rewrite <- app_assoc in IH.
      rewrite !it_mkLambda_or_LetIn_app in IH.
      cbn in IH.
      unfold mkLambda_or_LetIn in IH.
      rewrite decl_eq in *.
      cbn in *.

      rewrite decl_eq in *.
      specialize (IH (Γ' ++ [cd]) inner args args' t len_eq).
      rewrite vasses_app in IH.
      cbn in IH.
      rewrite decl_eq, app_nil_r in IH.
      specialize (IH len_eq').
      rewrite <- app_assoc in IH.
      rewrite !it_mkLambda_or_LetIn_app in IH.
      cbn in IH.
      unfold mkLambda_or_LetIn in IH.
      rewrite decl_eq in IH.
      rewrite <- app_tip_assoc in ev.
      rewrite <- app_assoc in ev.
      rewrite !it_mkLambda_or_LetIn_app in ev.
      cbn in ev.
      unfold mkLambda_or_LetIn in ev.
      rewrite decl_eq in ev.
      specialize (IH ev).
      clear ev.
      apply eval_mkApps_head in IH as ev_hd.
      destruct ev_hd as (hdv & ev_hd).
      eapply eval_mkApps_heads; [exact ev_hd| |easy].
      clear IH.
      eapply eval_mkApps_heads in IH.
      replace (List.rev args) with (skipn #|vasses [cd]| (List.rev args)); cycle 1.
      { cbn.
        now rewrite decl_eq. }
      replace (csubst t0 0 inner) with (close_term_aux [cd] inner (List.rev args));
        cycle 1.
      { cbn.
        now rewrite decl_eq. }
      rewrite <- close_term_aux_app; cycle 1.
      { cbn.
        rewrite decl_eq.
        now cbn. }
      cbn.
      rewrite decl_eq.
      change (csubst t0 0 inner) with (close_term_aux [c
      close_term_aux_app

      rewrite app_nil_r
      apply IH; [easy|easy|].
      easy.
  cbn in *.
  refold.
  unfold mkLambda_or_LetIn in *.
  destruct (decl_body cd) eqn:decl_eq.
  + apply IH; [|easy].
    apply eval_mkApps_head in ev as (s & s' & ->).
    destruct ev_hd as (hdv & ev_hd).
    eapply eval_mkApps_heads; [exact ev_hd| |exact ev].
  intros ev.
  remember (mkApps (it_mkLambda_or_LetIn Γ inner) args).
  induction ev using eval_evals_ind; subst.
  -

(*
Lemma valid_dearg_mask_eval_lambdas mask body Σ args t :
  valid_dearg_mask mask body ->
  #|args| = #|mask| ->
  env_closed Σ ->
  Forall (closedn 0) args ->
  Σ ⊢ mkApps body args ▷ t ->
  eval_lambdas Σ body args.
Proof.
  intros valid_mask len_eq env_clos all_clos ev.
  revert mask valid_mask len_eq all_clos.
  remember (mkApps body args).
  induction ev using eval_evals_ind; intros mask valid_mask len_eq all_clos;
    subst.
  - induction args using List.rev_ind.
    + cbn in *.
      subst body.
      easy.
    + rewrite mkApps_app in *.
      cbn in *.*)
  (* Cannot induct on body because our IH ends up talking about eval_lambdas on
     open term ... *)
  (*
  intros valid_mask len_eq env_clos.
  revert mask args t valid_mask len_eq.
  induction body using term_forall_list_ind; intros mask args t valid_mask len_eq all_clos ev;
    try solve [now destruct mask; [|easy]; destruct args; [|easy]; cbn in *].
  - cbn in *.
    destruct mask as [|b mask], args as [|a args]; cbn in *; try easy.
    exists n, body.
    split; [now apply eval_atom|].
    apply eval_mkApps_head in ev as ev_hd.
    destruct ev_hd as (hdv & ev_hd).
    apply eval_tApp_arg in ev_hd as (av & ev_a).

    apply eval_lambdas_tApp_tLambda with av; [easy|].
    apply eval_lambdas_csubst.
    eapply IHbody.
    * apply valid_dearg_mask_csubst; [easy|].
      eapply eval_closed; [eassumption| |easy].
      now inversion all_closed.
    * easy.
    * now inversion all_closed.
    * now eapply mkApps_csubst.
  cbn in *.
  intros valid_mask len_eq env_clos.
  revert mask body t valid_mask len_eq.
  induction args; intros mask body t valid_mask len_eq all_clos ev.
  - destruct mask as [|b mask]; [|easy].
    cbn in *.
    easy.
  - destruct mask as [|b mask]; [easy|].
    cbn in *.
    destruct body using term_forall_list_ind; try easy; cbn in *.
    + exists n, body.
      split; [apply eval_atom; easy|].
      apply eval_mkApps_head in ev as ev_hd.
      destruct ev_hd as (hdv & ev_hd).
      apply eval_tApp_arg in ev_hd as (av & ev_a).
      apply eval_lambdas_tApp_tLambda with av; [easy|].
      eapply (IHargs mask _).
      * apply valid_dearg_mask_csubst; [easy|].
        eapply eval_closed; [eassumption| |easy].
        now inversion all_clos.
      * easy.
      * now inversion all_clos.
      * now eapply mkApps_csubst.
    +
      cbn in *.
      * cbn in *.

      eexists _, _.

      specialize (IHargs _ _ _ valid_mask).
      eapply IHargs.
      eapply eval_lambdas_tApp_tLambda.
      pose proof (eval_tApp_head _ _ _ _ ev) as (hdv & ev_hd).
      pose proof (eval_tApp_arg _ _ _ _ ev) as (av & ev_a).
      eapply eval_lambdas_tApp_tLambda; [easy|].
      apply (IHargs mask _ hdv).
      * apply valid_dearg_mask_csubst; [easy|].
        eapply eval_closed; [eassumption| |easy].
        now destruct all_closed as (_ & clos); inversion clos.
      * lia.
      * easy.
      *

  induction args using List.rev_ind; intros mask body t valid_mask len_eq all_closed ev.
  - destruct mask as [|b mask]; [|easy].
    cbn in *.
    easy.
  - rewrite mkApps_app in ev.
    cbn in *.
    destruct mask as [|b mask].
    { now rewrite app_length in len_eq; cbn in *. }
    cbn in *.
    apply Forall_app in all_closed.
    rewrite List.rev_app_distr, app_length in *.
    destruct body; try easy.
    + cbn in *.
      exists n, body.
      split; [apply eval_atom; easy|].
      pose proof (eval_tApp_head _ _ _ _ ev) as (hdv & ev_hd).
      pose proof (eval_tApp_arg _ _ _ _ ev) as (av & ev_a).
      eapply eval_lambdas_tApp_tLambda; [easy|].
      apply (IHargs mask _ hdv).
      * apply valid_dearg_mask_csubst; [easy|].
        eapply eval_closed; [eassumption| |easy].
        now destruct all_closed as (_ & clos); inversion clos.
      * lia.
      * easy.
      *
    + cbn in *.
    rewrite List.rev_app_distr.
    cbn.
    destruct (valid_dearg_mask_spec (mask ++ [b]) body)
      as (Γ & inner & len_eq' & body_eq); [easy|].
    rewrite body_eq in valid_mask.
    rewrite app_length in len_eq'.
    induction Γ using List.rev_ind; [now cbn in *|].
    rewrite it_mkLambda_or_LetIn_app in *.
    cbn in valid_mask.
    + cbn in *.
    destruct body; try easy.
    + cbn in *.
      exists n, body.
      split; [now constructor|].
      apply eval_mkApps_head in ev as (app_val & app_ev).
      apply eval_tApp_arg in app_ev as ev_a.
      destruct ev_a as (av & ev_a).
      apply eval_lambdas_tApp_tLambda with av; [easy|].
      apply eval_tApp_head in app_ev as ev_hd.
      destruct ev_hd as (ev_hdv & ev_hd).
      apply (IHargs mask _ app_val).
      * apply valid_dearg_mask_csubst; [easy|].
        apply (eval_closed Σ a av); [easy| |easy].
        now inversion all_closed.
      * easy.
      * now inversion all_closed.
      *
        depelim app_ev.
      apply IHbody.
      apply eval_lambdas_tApp_tLambda

  destruct (valid_dearg_mask_spec _ _ valid_mask) as (Γ & inner & Γlen & ->).
  revert mask args t.
  induction body using term_forall_list_ind; intros mask args t valid_mask len_eq ev;
    cbn in *;
    try solve [destruct mask; [|easy];
               destruct args; [|easy];
               now cbn in *].
  - destruct mask as [|b mask], args as [|a args];
      cbn in *; try easy.
    exists n, body.
    split.
    + now apply eval_atom.
    + apply eval_mkApps_head in ev as (app_val & app_ev).
      apply eval_tApp_arg in app_ev as ev_a.
      destruct ev_a as (av & ev_a).
      apply eval_lambdas_tApp_tLambda with av; [easy|].
      apply IHbody.
  (*destruct (valid_dearg_mask_spec _ _ valid_mask) as (Γ & inner & Γlen & ->).
  revert args t inner len_eq ev Γlen valid_mask.*)
  induction Γ as [|cd Γ IH] using List.rev_ind; intros mask body t valid_mask len_eq ev.
  - cbn in *.
    destruct mask; [|easy].
    destruct args; [|easy].
    cbn in *.
    easy.
  - rewrite it_mkLambda_or_LetIn_app in *.
    rewrite vasses_app in *.
    cbn in *.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + apply eval_mkApps_head in ev as (let_in_res & ev_let_in).
      apply eval_LetIn in ev_let_in as (val_res & ev_val_res & subst_body_eval).
      eapply eval_lambdas_LetIn; [eassumption|].

      kcbn in *.
      rewrite app_nil_r in Γlen.
      specialize
Admitted.
*)

(*
Lemma dearg_single_correct_full Σ body args t mask :
  eval_lambdas Σ body args ->
  Σ ⊢ mkApps body args ▷ t ->
  valid_dearg_mask mask body ->
  length args = length mask ->
  Σ ⊢ dearg_single mask (dearg_cst_body_top mask body) args ▷ t.
Proof.
*)

Lemma dearg_single_correct mask body args Σ t :
  Σ ⊢ mkApps body args ▷ t ->
  valid_dearg_mask mask body ->
  #|args| = #|mask| ->
  Σ ⊢ dearg_single mask (dearg_cst_body_top mask body) args ▷ t.
Proof.
  intros ev valid_mask len_eq.
  destruct (valid_dearg_mask_spec _ _ valid_mask) as (Γ & inner & Γlen & ->).
  revert mask args t inner valid_mask eval len_eq Γlen.
  induction Γ as [|cd Γ IH] using List.rev_ind; intros mask args t inner valid_mask ev len_eq Γlen.
  - cbn in *.
    destruct mask; [|easy].
    destruct args; [|easy].
    cbn.
    now rewrite dearg_cst_body_top_nil.
  - rewrite vasses_app, app_length in Γlen.
    rewrite it_mkLambda_or_LetIn_app in *.
    cbn in *.
    unfold mkLambda_or_LetIn in *.
    destruct (decl_body cd) eqn:decl_eq.
    + cbn in *.
      admit.
    + cbn in *.
      destruct mask as [|b mask]; [easy|].
      destruct args as [|a args]; [easy|].
      destruct b.
      * cbn.
      cbn.


Lemma foo :
  #|mask| = #|args| ->
  Σ ⊢ dearg_single mask  args ▷ res

Inductive eval_apps Σ res : term -> list term -> Prop :=
| eval_apps_nil t : Σ ⊢ t ▷ res -> eval_apps_nil Σ res t []
| eval_apps_cons t args :
    eval_apps Σ res t args ->
    Σ ⊢ tApp t

Fixpoint mkApps_eval_spine :
  -> mkApps t


      Σ ⊢ mkApps hd args ▷ res
  apply eval_mkApps_subst_context in eval; [|congruence].

  induction Γ.
  - cbn in *.
    destruct mask; [|easy].
    destruct args; [|easy].
    now rewrite dearg_cst_body_top_nil.
  - cbn in *; refold.


    rewrite <- it_mkLambda_or_LetIn_unfold in *.
  revert mask body t.
  induction args as [|a args IH] using List.rev_ind; intros mask body t eval valid_mask len_eq.
  - destruct mask as [|b mask]; [|easy].
    now rewrite dearg_cst_body_top_nil.
  - rewrite mkApps_app.
    rewrite app_length in len_eq.
    destruct mask as [|b mask] using List.rev_ind.
    + rewrite dearg_cst_body_top_nil.
      cbn.
      now rewrite Prelim.emkApps_snoc.
    + clear IHmask.
      rewrite app_length in len_eq.
      rewrite dearg_single_snoc by (cbn in *; abstract lia).
      destruct b.
      * destruct (dearg_cst_body_top_snoc_true mask body valid_mask)
          as (na & Γ & inner & -> & ->).

        destruct (valid_dearg_mask_snoc_true mask body valid_mask)
          as (na & inner_body & -> & no_use & valid_inner & ->).
        apply IH; [|easy|cbn in *; abstract lia].
      admit.
      unfold dearg_single.
      intros
    inversion eval; subst; clear eval.
    +
      destruct b.
      *
  intros eval valid_mask.
  revert args t eval mask valid_mask.
  induction body using term_forall_list_ind; intros args t eval mask valid_mask len_eq;
    try solve [
          cbn in *;
          destruct mask as [|[] ?];
          now rewrite ?dearg_single_0_mask].
  - cbn in *.
    clear IHbody.
    revert mask valid_mask len_eq.
    induction args as [|a args IH]; cbn in *; intros mask valid_mask len_eq.
    + destruct mask; easy.
    + destruct mask as [|b mask]; [easy|].
      destruct b; cbn in *.
      *
    admit.
  - cbn in *.
    induction mask as [|b mask]; [easy|].
    destruct args as [|a args]; [easy|].
    destruct b; cbn in *.
    + (* Arg was removed, use the fact that there is no use to show that unlift
         commutes with beta application in this case. *)

    destruct mask as [|[] ?].
    + cbn in *.

  - cbn in *.
    destruct mask as [|[] ?].
    + easy.
    + now rewrite dearg_single_0_mask by easy.
    + now rewrite dearg_single_0_mask by easy.
  - cbn in *.
    assert (Forall (eq false) mask).
    { destruct mask as [|[] ?]; auto. }
    rewrite dearg_single_0_mask by easy.

  - cbn in *.
    destruct mask; [|easy].
    cbn.
    now rewrite dearg_cst_body_top_nil.
  - destruct mask as [|b mask]; [easy|].
    cbn in *.
    destruct b.
    + induction body using term_forall_list_ind;
        try solve [cbn in *; inversion_clear valid_mask; congruence].
      * cbn in *.
        inversion_clear valid_mask; try congruence.
      * cbn in *.
        inversion_clear valid_mask.

Definition const_mask_wf_top Σ (p : kername * bitmask) : Prop :=
  exists cst,
    declared_constant Σ p.1 cst /\
    match cst_body cst with
    | Some body => valid_dearg_mask p.2 body
    | None => False
    end.

Definition const_masks_wf_top Σ : Prop :=
  Forall (const_mask_wf_top Σ) const_masks.

Fixpoint enough_lambdas (mask : bitmask) (body : term) : Prop :=
  match mask, body with
  | _ :: mask, tLambda _ body => enough_lambdas mask body
  | mask, _ => Forall (eq false) mask
  end.

Definition case_shape
           (ind : inductive) (npars : nat)
           (brs : list (nat * term)) : Prop :=
  match get_mib_masks ind_masks (inductive_mind ind) with
  | Some mib_masks =>
    npars = length (param_mask mib_masks) /\
    ∥ Alli (fun c '(_, br) =>
            match find (fun '(ind', c', _) => (ind' =? inductive_ind ind) && (c' =? c))
                       (ctor_masks mib_masks) with
            | Some (_, _, mask) => enough_lambdas mask br
            | None => True
            end)
         0 brs ∥
  | None => True
  end.

(* Proposition representing that all case branches have the correct shapes
   (iterated lambdas) to be dearged. *)
Fixpoint case_shapes (t : term) : Prop :=
  match t with
  | tBox => True
  | tRel _ => True
  | tVar _ => True
  | tEvar _ ts => fold_right and True (map case_shapes ts)
  | tLambda _ body => case_shapes body
  | tLetIn _ val body => case_shapes val /\ case_shapes body
  | tApp hd arg => case_shapes arg /\ case_shapes hd
  | tConst kn => True
  | tConstruct ind c => True
  | tCase (ind, npars) discr brs => case_shape ind npars brs /\
                                    fold_right and True (map (case_shapes ∘ snd) brs)
  | tProj p t => case_shapes t
  | tFix defs _
  | tCoFix defs _ => fold_right and True (map (case_shapes ∘ dbody) defs)
  end.

Notation dearg_ctor := (dearg_ctor ind_masks).
Notation dearg_consts := (dearg_const const_masks).
Notation dearg_case := (dearg_case ind_masks).
Notation dearg_aux := (dearg_aux ind_masks const_masks).
Notation dearg := (dearg ind_masks const_masks).
Notation dearg_cst := (dearg_cst ind_masks const_masks).
Notation dearg_mib := (dearg_mib ind_masks).
Notation dearg_decl := (dearg_decl ind_masks const_masks).
Notation dearg_env := (dearg_env ind_masks const_masks).

Theorem dearg_env_eval Σ s t :
  trans Σ ⊢ s ▷ t ->
  const_masks_wf_top Σ ->
  trans (dearg_env Σ) ⊢ dearg s ▷ dearg t.
Proof.