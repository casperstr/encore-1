{-# LANGUAGE MultiParamTypeClasses, TypeSynonymInstances, FlexibleInstances, GADTs, NamedFieldPuns #-}

{-| Translate a @ClassDecl@ (see "AST") to its @CCode@ (see
"CCode.Main") equivalent.

 -}

module CodeGen.ClassDecl () where

import CodeGen.Typeclasses
import CodeGen.CCodeNames
import CodeGen.MethodDecl
import CodeGen.Type
import qualified CodeGen.Context as Ctx

import CCode.Main
import CCode.PrettyCCode

import Data.List

import qualified AST.AST as A
import qualified Identifiers as ID
import qualified Types as Ty

import Control.Monad.Reader hiding (void)

instance Translatable A.ClassDecl (CCode FIN) where
  translate cdecl
      | A.isActive cdecl = translateActiveClass cdecl
      | otherwise        = translatePassiveClass cdecl

-- | Translates an active class into its C representation. Note
-- that there are additional declarations in the file generated by
-- "CodeGen.Header"
translateActiveClass cdecl@(A.Class{A.cname, A.fields, A.methods}) =
    Program $ Concat $
      (LocalInclude "header.h") :
      [type_struct] ++
      [tracefun_decl cdecl] ++
      method_impls ++
      [dispatchfun_decl] ++
      [pony_type_t_decl cname]
    where
      type_struct :: CCode Toplevel
      type_struct = StructDecl (AsType $ class_type_name cname) $
                     ((encore_actor_t, Var "_enc__actor") :
                         zip
                         (map (translate  . A.ftype) fields)
                         (map (Var . show . A.fname) fields))

      pony_msg_t_impls :: [CCode Toplevel]
      pony_msg_t_impls = map pony_msg_t_impl methods
          where
            pony_msg_t_impl :: A.MethodDecl -> CCode Toplevel
            pony_msg_t_impl mdecl =
              let argrttys = map (translate . A.getType) (A.mparams mdecl)
                  argnames = map (Var . ("f"++) . show)  ([1..] :: [Int])
                  argspecs = zip argrttys argnames :: [CVarSpec]
                  encoremsgtspec = (enc_msg_t, Var "msg")
                  encoremsgtspec_oneway = (enc_oneway_msg_t, Var "msg")
                  nameprefix = "encore_"++ (show (A.cname cdecl))
                                ++ "_" ++ (show (A.mname mdecl))
              in Concat [StructDecl (Typ $ nameprefix ++ "_fut_msg") (encoremsgtspec : argspecs)
                        ,StructDecl (Typ $ nameprefix ++ "_oneway_msg") (encoremsgtspec_oneway : argspecs)]

      -- message_type_decl :: CCode Toplevel
      -- message_type_decl =
      --     Function (Static . Ptr . Typ $ "pony_msg_t")
      --              (class_message_type_name cname)
      --              [(Typ "uint64_t", Var "id")]
      --              (Seq [Switch (Var "id")
      --                      ((Nam "MSG_alloc", Return $ Amp $ Var "m_MSG_alloc") :
      --                       (Nam "FUT_MSG_RESUME", Return $ Amp $ Var "m_resume_get") :
      --                       (Nam "FUT_MSG_SUSPEND", Return $ Amp $ Var "m_resume_suspend") :
      --                       (Nam "FUT_MSG_AWAIT", Return $ Amp $ Var "m_resume_await") :
      --                       (Nam "FUT_MSG_RUN_CLOSURE", Return $ Amp $ Var "m_run_closure") :
      --                       (concatMap type_clause methods))
      --                       (Skip),
      --                    (Return Null)])
      --   where
      --     type_clause mdecl =
      --         [message_type_clause cname (A.mname mdecl),
      --          one_way_message_type_clause cname (A.mname mdecl)]
      --     message_type_clause :: Ty.Type -> ID.Name -> (CCode Name, CCode Stat)
      --     message_type_clause cname mname =
      --         if mname == (ID.Name "main") then
      --             (Nam "PONY_MAIN",
      --              Return $ Amp (method_message_type_name cname mname))
      --         else
      --       (method_msg_name cname mname,
      --        Return $ Amp (method_message_type_name cname mname))

      --     one_way_message_type_clause :: Ty.Type -> ID.Name -> (CCode Name, CCode Stat)
      --     one_way_message_type_clause cname mname =
      --       (one_way_send_msg_name cname mname,
      --        Return $ Amp (one_way_message_type_name cname mname))

      method_impls = map method_impl methods
          where
            method_impl mdecl = translate mdecl cdecl

      dispatchfun_decl :: CCode Toplevel
      dispatchfun_decl =
          (Function (Static void) (class_dispatch_name cname)
           ([(Ptr . Typ $ "pony_actor_t", Var "_a"),
             (Ptr . Typ $ "pony_msg_t", Var "_m")])
           (Seq [Assign (Decl (Ptr . AsType $ class_type_name cname, Var "this"))
                        (Cast (Ptr . AsType $ class_type_name cname) (Var "_a")),
                 (Switch (Var "_m" `Arrow` Nam "id")
                  (
                   -- (Nam "_ENC__MSG_RESUME_SUSPEND", fut_resume_suspend_instr) :
                   -- (Nam "_ENC__MSG_RESUME_AWAIT", fut_resume_await_instr) :
                   -- (Nam "_ENC__MSG_RUN_CLOSURE", fut_run_closure_instr) :
                   (if (A.isMainClass cdecl)
                    then pony_main_clause : (method_clauses $ filter ((/= ID.Name "main") . A.mname) methods)
                    else method_clauses $ methods
                   ))
                  (Statement $ Call (Nam "printf") [String "error, got invalid id: %zd", AsExpr $ (Var "_m") `Arrow` (Nam "id")]))]))
           where
             fut_resume_instr =
                 Seq
                   [Assign (Decl (Ptr $ Typ "future_t", Var "fut"))
                           ((ArrAcc 0 (Var "argv")) `Dot` (Nam "p")),
                    Statement $ Call (Nam "future_resume") [Var "fut"]]

             fut_resume_suspend_instr =
                 Seq
                   [Assign (Decl (Ptr $ Typ "void", Var "s"))
                           ((ArrAcc 0 (Var "argv")) `Dot` (Nam "p")),
                    Statement $ Call (Nam "future_suspend_resume") [Var "s"]]

             fut_resume_await_instr =
                 Seq
                   [Statement $ Call (Nam "future_await_resume") [Var "argv"]]

             fut_run_closure_instr =
                 Seq
                   [Assign (Decl (closure, Var "closure"))
                           ((ArrAcc 0 (Var "argv")) `Dot` (Nam "p")),
                    Assign (Decl (Typ "value_t", Var "closure_arguments[]"))
                           (Record [UnionInst (Nam "p") (ArrAcc 1 (Var "argv") `Dot` (Nam "p"))]),
                    Statement $ Call (Nam "closure_call") [Var "closure", Var "closure_arguments"]]

             pony_main_clause =
                 (Nam "_ENC__MSG_MAIN",
                  Seq $ [Assign (Decl (Ptr $ Typ "pony_main_msg_t", Var "msg")) (Cast (Ptr $ Typ "pony_main_msg_t") (Var "_m")),
                         Statement $ Call ((method_impl_name (Ty.refType "Main") (ID.Name "main")))
                                          [(Cast (Ptr $ Typ "_enc__active_Main_t") (Var "_a")),
                                           AsExpr $ (Var "msg") `Arrow` (Nam "argc"),
                                           AsExpr $ (Var "msg") `Arrow` (Nam "argv")]])

             method_clauses :: [A.MethodDecl] -> [(CCode Name, CCode Stat)]
             method_clauses = concatMap method_clause

             method_clause m = (mthd_dispatch_clause m) :
                               if not (A.isStreamMethod m)
                               then [one_way_send_dispatch_clause m]
                               else []

             -- explode _enc__Foo_bar_msg_t struct into variable names
             method_unpack_arguments :: A.MethodDecl -> [CCode Stat]
             method_unpack_arguments mdecl@(A.Method{A.mname, A.mparams, A.mtype}) = 
               map unpack mparams
                 where
                   unpack A.Param{A.pname, A.ptype} = (Assign (Decl (translate ptype, (Var $ show pname))) ((Cast (msg_type_name) (Var "_m")) `Arrow` (Nam $ show pname)))
                     where
                       msg_type_name = Ptr $ Typ $ "struct _enc__" ++ (show (A.cname cdecl)) ++ "_" ++ (show (A.mname mdecl)) ++ "_fut_msg"

             mthd_dispatch_clause mdecl@(A.Method{A.mname, A.mparams, A.mtype})  =
                (method_msg_name cname mname,
                 Seq ((Assign (Decl (Ptr $ Typ "future_t", (Var "_fut"))) ((Cast (Ptr $ enc_msg_t) (Var "_m")) `Arrow` (Nam "_fut"))) :
                      ((method_unpack_arguments mdecl) ++
                      gc_recv mparams ++
                      [Statement $ Call (Nam "future_fulfil")
                                        [AsExpr $ Var "_fut",
                                         Cast (Ptr void)
                                              (Call (method_impl_name cname mname)
                                              ((AsExpr . Var $ "this") :
                                              (map method_argument mparams)))]])))
             mthd_dispatch_clause mdecl@(A.StreamMethod{A.mname, A.mparams})  =
                (method_msg_name cname mname,
                 Seq [Assign (Decl (Ptr $ Typ "future_t", Var "fut"))
                      ((ArrAcc 0 ((Var "argv"))) `Dot` (Nam "p")),
                      Statement $ Call (method_impl_name cname mname)
                                        ((AsExpr . Var $ "p") :
                                         (AsExpr . Var $ "fut") :
                                         (map method_argument mparams))])

             one_way_send_dispatch_clause mdecl@A.Method{A.mname, A.mparams} =
                (one_way_send_msg_name cname mname,
                 Seq ((method_unpack_arguments mdecl) ++
                     gc_recv mparams ++
                     [Statement $ Call (method_impl_name cname mname) ((AsExpr . Var $ "this") : (map method_argument mparams))]))

             method_argument A.Param {A.pname} = AsExpr (Var $ show pname)

             gc_recv ps = [Embed $ "", 
                           Embed $ "// --- GC on receive ----------------------------------------",
                           Statement $ Call (Nam "pony_gc_recv") [Null]] ++
                          (map tracefun_calls ps) ++
                          [Statement $ Call (Nam "pony_recv_done") [Null],
                           Embed $ "// --- GC on receive ----------------------------------------",
                           Embed $ ""]

             -- XXX: Add scanning the future as well as a maybe arg
             -- XXX: Move to Expr.hs
             gc_send ps = [Embed $ "", 
                           Embed $ "// --- GC on sending ----------------------------------------",
                           Statement $ Call (Nam "pony_gc_send") [Null]] ++
                          (map tracefun_calls ps) ++
                          [Statement $ Call (Nam "pony_send_done") [Null],
                           Embed $ "// --- GC on sending ----------------------------------------",
                           Embed $ ""]

             tracefun_calls A.Param{A.pname, A.ptype} = tracefun_call_each pname ptype
               where 
               tracefun_call_each n t 
                   | Ty.isActiveRefType  t = Statement $ Call (Nam "pony_traceactor")  [Var $ show n]
                   | Ty.isPassiveRefType t = Statement $ Call (Nam "pony_traceobject") [Var $ show n, AsLval $ class_trace_fn_name t]
                   | otherwise             = Embed $ "/* Not tracing '" ++ show n ++ "' */"
 
-- | Translates a passive class into its C representation. Note
-- that there are additional declarations (including the data
-- struct for instance variables) in the file generated by
-- "CodeGen.Header"
translatePassiveClass cdecl@(A.Class{A.cname, A.fields, A.methods}) =
    Program $ Concat $
      (LocalInclude "header.h") :
      [tracefun_decl cdecl] ++
      method_impls ++
      [pony_type_t_decl cname]

    where
      method_impls = map method_decl methods
          where
            method_decl mdecl = translate mdecl cdecl

tracefun_decl :: A.ClassDecl -> CCode Toplevel
tracefun_decl A.Class{A.cname, A.fields, A.methods} = 
    case find ((== Ty.getId cname ++ "_trace") . show . A.mname) methods of
      Just mdecl@(A.Method{A.mbody, A.mname}) ->
          Function void (class_trace_fn_name cname) 
                   [(Ptr void, Var "p")]
                   (Statement $ Call (method_impl_name cname mname)
                                [Var "p"])
      Nothing -> 
          Function void (class_trace_fn_name cname) 
                   [(Ptr void, Var "p")]
                   (Seq $ 
                    (Assign (Decl (Ptr . AsType $ class_type_name cname, Var "this"))
                            (Var "p")) :
                     map (Statement . trace_field) fields)
    where
      trace_field A.Field {A.ftype, A.fname}
          | Ty.isActiveRefType ftype =
              Call (Nam "pony_traceactor") [get_field fname]
          | Ty.isPassiveRefType ftype =
              Call (Nam "pony_traceobject") 
                   [get_field fname, AsLval $ class_trace_fn_name ftype]
          | otherwise =
              Embed $ "/* Not tracing field '" ++ show fname ++ "' */"

      get_field f = 
          (Var "this") `Arrow` (Nam $ show f)


pony_type_t_decl cname =
    (AssignTL
     (Decl (Typ "pony_type_t", AsLval $ runtime_type_name cname))
           (Record [AsExpr . AsLval . Nam $ ("ID_"++(Ty.getId cname)),
                    Call (Nam "sizeof") [AsLval $ class_type_name cname],
                    AsExpr . AsLval $ (class_trace_fn_name cname),
                    Null,
                    Null,           
                    AsExpr . AsLval $ class_dispatch_name cname,
                    Null]))
