(** * Term and proof generation for the certifying transforms *)
From Coq Require Import List.
From Coq Require Import Ascii.
From Coq Require Import String.
From MetaCoq.Template Require Import Kernames.
From MetaCoq.Template Require Import All.
From MetaCoq.Template Require Import Checker.

Open Scope bs.
Import MCMonadNotation.

(* TODO: at some point we should provide StringExtra for byte strings *)
Definition replace_char (orig : ascii) (new : ascii) : String.string -> String.string :=
  fix f s :=
    match s with
    | EmptyString => EmptyString
    | String c s => if (c =? orig)%char then
                      String new (f s)
                    else
                      String c (f s)
    end.

Definition get_def_name (name : kername) : string :=
  let s_name := bytestring.String.to_string (string_of_kername name) in
  bytestring.String.of_string (replace_char "." "_" s_name).

Definition change_modpath (mpath : modpath) (suffix : string) (to_rename : kername -> bool)
  : term -> term :=
  fix go (t : term) : term :=
    match t with
    | tRel n => t
    | tVar id => t
    | tSort s => t
    | tEvar ev args => tEvar ev (map go args)
    | tCast t kind v => tCast (go t) kind (go v)
    | tProd na ty body => tProd na (go ty) (go body)
    | tLambda na ty body => tLambda na (go ty) (go body)
    | tLetIn na def def_ty body =>
      tLetIn na (go def) (go def_ty) (go body)
    | tApp f args => tApp (go f) (map go args)
    | tConst kn u => if to_rename kn then
                      tConst (mpath, get_def_name kn ++ suffix) u
                    else t
    | tInd ind u => t
    | tConstruct ind idx u => t
    | tCase ci p discr branches =>
      tCase ci (map_predicate id go go p)
            (go discr) (map_branches go branches)
    | tProj proj t => tProj proj (go t)
    | tFix mfix idx => tFix (map (map_def go go) mfix) idx
    | tCoFix mfix idx => tCoFix (map (map_def go go) mfix) idx
    | tInt n => tInt n
    | tFloat n => tFloat n
  end.

Fixpoint map_constants_global_decls (k : kername -> kername) (f : constant_body -> constant_body) (?? : global_declarations) : global_declarations :=
  match ?? with
  | [] => []
  | (kn, ConstantDecl cb) :: ??' => (k kn, ConstantDecl (f cb)) :: map_constants_global_decls k f ??'
  | gd :: ??' => gd :: map_constants_global_decls k f ??'
  end.

Definition map_constants_global_env (k : kername -> kername) (f : constant_body -> constant_body) (?? : global_env) : global_env :=
  {| universes := ??.(universes);
     declarations := map_constants_global_decls k f ??.(declarations);
     retroknowledge := ??.(retroknowledge) |}.

Definition add_suffix_global_env (mpath : modpath) (suffix : string) (expansion_ignore : kername -> bool) (?? : global_env) :=
  map_constants_global_env
    (fun kn => (mpath,get_def_name kn ++ suffix))
    (fun cb => {| cst_type := change_modpath mpath suffix expansion_ignore cb.(cst_type);
                cst_body := b <- cb.(cst_body);;
                           Some (change_modpath mpath suffix expansion_ignore b);
              cst_universes := cb.(cst_universes);
              cst_relevance := cb.(cst_relevance) |}) ??.

Definition generate_proof_term (ty : term) (kn1 kn2 : kername) : term ?? term :=
  let proof_ty :=
      tApp <% @eq %> [ty; tConst kn1 []; tConst kn2 []] in
  let proof_body :=
      tApp <% @eq_refl %> [ty; tConst kn2 []] in
      (proof_ty, proof_body).

Definition gen_prog (ty body : term) (kn : kername) : TemplateMonad unit :=
  tmBind (tmUnquoteTyped Type ty)
         (fun A => ucst <- tmUnquoteTyped A body ;;
                  tmDefinition kn.2 ucst;;
                  ret tt).

Definition gen_proof (suffix : string) (?? : global_declarations) (mpath : modpath) (kn : kername) : TemplateMonad unit :=
  match lookup_global ?? kn with
  | Some (ConstantDecl cb) =>
    let kn_after := (mpath, get_def_name kn ++ suffix) in
    '(p_ty, p_t) <- tmEval lazy (generate_proof_term cb.(cst_type) kn kn_after) ;;
    tmBind (tmUnquoteTyped Type p_ty)
           (fun B =>
              uproof <- tmUnquoteTyped B p_t ;;
              tmDefinition (kn_after.2 ++ "_convertible") uproof ;;
              tmPrint B)
  | _ => tmFail ("Not a defined constant" ++ string_of_kername kn)
  end.

Definition is_none {A} (o : option A) :=
  match o with
  | Some _ => false
  | None => true
  end.

Definition map_global_env_decls (f : global_declarations -> global_declarations)
           (?? : global_env) : global_env :=
  {| universes := ??.(universes);
     declarations := f ??.(declarations);
     retroknowledge := ??.(retroknowledge) |}.

(** Given the two environments [??1] and [??2] we traverse the first and lookup constants
    with the same name in the second. If such a constant is found, we compare the bodies
    for (syntactic) equality. If they are not equal, we expect them to be convertible, so
    we generate a new definition and save the name to [affected] list, which is returned
    when we traversed all definition in [??1] *)
Definition traverse_env (mpath : modpath) (suffix : string) (??1 ??2 : global_declarations) :=
  let f := fix go (affected : KernameSet.t) (d??1 d??2 : global_declarations) : TemplateMonad KernameSet.t :=
      match d??1 with
      | [] => ret affected
      | (kn, ConstantDecl cb1) :: ??tail =>
          match lookup_global ??2 kn with
          | Some (ConstantDecl cb2) =>
              match cb1, cb2 with
              | Build_constant_body ty1 (Some body1) _ _,
                (Build_constant_body ty2 (Some body2) _ _ ) =>
                  new_body2 <- tmEval lazy (change_modpath mpath suffix (fun kn => KernameSet.mem kn affected) body2);;
                  new_ty2 <-tmEval lazy (change_modpath mpath suffix (fun kn => KernameSet.mem kn affected) ty2);;
                  if @Checker.eq_term config.default_checker_flags init_graph body1 new_body2 then
                    go affected ??tail d??2
                  else
                    gen_prog new_ty2 new_body2 (mpath, get_def_name kn ++ suffix);;
                    go (KernameSet.add kn affected) ??tail d??2
              | _,_ => go affected ??tail d??2
              end
          | Some _ | None => go affected ??tail d??2
          end
      | _ :: ??tail => go affected ??tail d??2
      end in
  f KernameSet.empty ??1 ??2.

(** We generate new definitions using [traverse_env] and then generate the proofs for all
   affected seeds. The proof is just [eq_refl], since we expect that the generated
   definitions are convertible to the originals. At this point all the affected definitions
   have been added to the current scope given by [mpath].
 *)
(** NOTE: we generate proofs for all affected constants, but we don't gnerate proofs of
    the types of constructors, that can be affected by inlining within types! *)
Definition gen_defs_and_proofs (??old ??new : global_declarations)
                               (mpath : modpath)
                               (suffix : string)
                               (seeds : KernameSet.t)
                               : TemplateMonad unit :=
  let filter_decls decls :=
    filter (fun '(kn,gd) =>
              match gd with
              | ConstantDecl cb => negb (is_none cb.(cst_body))
              | _ => false
              end) decls in
  let filtered??old := filter_decls ??old in
  let filtered??new := filter_decls ??new in
  affected_defs <- traverse_env mpath suffix (List.rev filtered??old) filtered??new;;
  let affected_seeds := KernameSet.inter affected_defs seeds in
  monad_iter (gen_proof suffix ??new mpath) (KernameSet.elements affected_seeds).
