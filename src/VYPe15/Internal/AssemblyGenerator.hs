{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module VYPe15.Internal.AssemblyGenerator
    ( generateAssembly
    )
  where

import Prelude (Integral, Num, error, fromIntegral, negate)

import Control.Applicative (pure)
import Control.Monad (mapM_, return, (>>), (>>=))
import Control.Monad.State (get, modify, put)
import Control.Monad.Writer (tell)
import Data.Bool (Bool(False, True))
import Data.Char (ord)
import Data.Function (($), (.))
import Data.Functor ((<$>))
import Data.Int (Int32)
import Data.List (groupBy, reverse)
import qualified Data.Map as M (empty)
import Data.Maybe (Maybe(Just, Nothing))
import Data.Monoid ((<>))
import Data.Text (Text)

import VYPe15.Internal.Util (showText)
import VYPe15.Types.Assembly
    ( ASM(ADD, ADDI, AND, B, BEQ, BGE, BGT, BLE, BLT, BNE, DIV, JAL, JR, LB, LI, LW, Label, MFHi, MFLo, MOV, MUL, OR, PrintChar, PrintInt, PrintString, SB, SUB, SW, XOR)
    , Address(RAM)
    , Assembly
    , AssemblyState(AssemblyState, functionLabel, labelCounter, paramCounter, stringCounter, stringTable, variableCounter, variableTable)
    , Register(A0, FP, RA, SP, T0, T1, T2, V0, Zero)
    , addParam
    , addVariable
    , evalAssembly
    , getFunctionLabel
    , getReturnLabel
    , getVarAddr
    , lookupVarAddr
    , mkLabel
    )
import VYPe15.Types.AST
    ( DataType(DChar, DInt, DString)
    , Identifier(getId)
    , Param(AnonymousParam, Param)
    , getTypeSize
    )
import VYPe15.Types.SymbolTable
    (Function(functionParams), Variable(Variable, varType))
import VYPe15.Types.TAC (Constant, Label, Operator, TAC)
import qualified VYPe15.Types.TAC as C (Constant(Char, Int, String))
import qualified VYPe15.Types.TAC as TAC
    ( TAC(Assign, Begin, Call, Goto, JmpZ, Label, PopParams, Print, PushParam, Return)
    )
import qualified VYPe15.Types.TAC as Op
    ( Operator(Add, And, Const, Div, Eq, GE, GT, LE, LT, Mod, Mul, Neq, Not, Or, Set, Sub)
    )


generateAssembly :: [TAC] -> Text
generateAssembly tac =
    -- intercalate "\n\n" (showText <$> functions tac)
    -- showText $ fmap (evalAssembly initialState . generateAssembly') $ functions tac
    showText . evalAssembly initialState . mapM_ generateAssembly' . reverse $ functions tac
  where
    functions = groupBy (\_ b -> isBegin b)

    isBegin = \case
        TAC.Begin _ _ -> False
        _ -> True

    initialState = AssemblyState
      { variableTable = M.empty
      , stringTable = []
      , stringCounter = 0
      , paramCounter = 0
      , variableCounter = 0
      , labelCounter = 0
      , functionLabel = "__quit_program__"
      }

    generateAssembly' :: [TAC] -> Assembly ()
    generateAssembly' tac' = do
        state <- get
        let (state', asm) = evalAssembly state $ mapM_ handleTAC tac'
        put state'
        postProcess asm

    postProcess :: [ASM] -> Assembly ()
    postProcess asm = do
        returnL <- getReturnLabel
        functionL <- getFunctionLabel
        stackSize <- variableCounter <$> get
        -- Point-free version of lambda function: ((. varSize) . (+))
        -- Intro
        tell
          [ Label functionL
          , SW RA (sp 0)
          , SW FP (sp 4)
          , ADDI SP (-8)
          , MOV FP SP
          , ADDI SP $ negate stackSize
          ]
        tell asm
        -- Outro
        tell
          [ Label returnL
          , MOV SP FP
          , LW FP (sp 4)
          , LW RA (sp 8)
          , JR RA
          ]

    sp :: Int32 -> Address
    sp = RAM SP

handleTAC :: TAC -> Assembly ()
handleTAC t = case t of
    TAC.Assign var op -> handleAssign var op
    TAC.Call mvar l -> handleCall mvar l
    TAC.PushParam var -> handlePushParam var
    TAC.PopParams n -> tell [ADDI SP $ fromIntegral n]
    TAC.Label l -> tell [Label l]
    TAC.Begin l fn -> handleBegin l fn
    TAC.JmpZ var l -> handleJmpZ var l
    TAC.Goto l -> tell [B l]
    TAC.Return mvar -> handleReturn mvar
    TAC.Print var -> handlePrint var

handleAssign :: Variable -> Operator -> Assembly ()
handleAssign dst = \case
    Op.Mul v1 v2 -> binaryOpMFReg MUL MFLo v1 v2
    Op.Div v1 v2 -> binaryOpMFReg DIV MFLo v1 v2
    Op.Mod v1 v2 -> binaryOpMFReg DIV MFHi v1 v2
    Op.Sub v1 v2 -> binaryOp SUB v1 v2
    Op.Add v1 v2 -> binaryOp ADD v1 v2
    Op.Set v -> loadVar T0 v >> storeVar T0 dst -- TODO: Type casting
    Op.And v1 v2 -> binaryOp AND v1 v2
    Op.Or  v1 v2 -> binaryOp OR v1 v2
    Op.Not v -> do
        loadVar T0 v
        tell
          [ LI T1 1
          , XOR T0 T1 T2
          ]
        storeVar T2 dst
    Op.Eq v1 v2 -> binaryOpLogic BEQ v1 v2 "Eq"
    Op.Neq v1 v2 -> binaryOpLogic BNE v1 v2 "Neq"
    Op.LT v1 v2 -> binaryOpLogic BLT v1 v2 "LT"
    Op.LE v1 v2 -> binaryOpLogic BLE v1 v2 "LE"
    Op.GT v1 v2 -> binaryOpLogic BGT v1 v2 "GT"
    Op.GE v1 v2 -> binaryOpLogic BGE v1 v2 "GE"
    Op.Const c -> loadConstant c
  where
    loadVar :: Register -> Variable -> Assembly ()
    loadVar r v = do
        v' <- getVarAddr v
        tell [lv v r v']

    storeVar :: Register -> Variable -> Assembly ()
    storeVar r v = do
        v' <- lookupVarAddr v >>= \case
            Just addr -> return addr
            Nothing -> addVariable v
        tell [sv v r v']

    binaryOp
      :: (Register -> Register -> Register -> ASM)
      -> Variable
      -> Variable
      -> Assembly ()
    binaryOp op v1 v2 = do
        loadVar T0 v1
        loadVar T1 v2
        tell [op T0 T1 T2]
        storeVar T2 dst

    binaryOpMFReg
      :: (Register -> Register -> ASM)
      -> (Register -> ASM)
      -> Variable
      -> Variable
      -> Assembly ()
    binaryOpMFReg op mf v1 v2 = do
        loadVar T0 v1
        loadVar T1 v2
        tell
          [ op T0 T1
          , mf T2
          ]
        storeVar T2 dst

    binaryOpLogic
      :: (Register -> Register -> Label -> ASM)
      -> Variable
      -> Variable
      -> Text
      -> Assembly ()
    binaryOpLogic branch v1 v2 labelName = do
        loadVar T0 v1
        loadVar T1 v2
        l <- mkLabel labelName
        tell
          [ LI T2 1
          , branch T0 T1 l
          , LI T2 0
          , Label l
          ]
        storeVar T2 dst

    loadConstant :: Constant -> Assembly ()
    loadConstant = \case
        C.Int n -> loadVal dst n
        C.Char n -> loadVal dst $ ord n
        C.String _s -> storeVar Zero dst -- Memory allocation strategy is needed.

    loadVal :: (Integral a) => Variable -> a -> Assembly ()
    loadVal v n = do
       tell [LI T0 $ fromIntegral n]
       storeVar T0 v

handleBegin ::  Label -> Function -> Assembly ()
handleBegin l fn = do
    modify (\s -> s
        { variableTable = M.empty
        , functionLabel = l
        , variableCounter = 0
        , paramCounter = 12 -- There is offset due to stack frame.
        })
    mapM_ (addParam . paramToVar)  $ functionParams fn
  where
    paramToVar (Param dt id) = Variable (getId id) dt
    paramToVar (AnonymousParam _) = error "BUG: Unexpected anonymous param."

handlePushParam :: Variable -> Assembly ()
handlePushParam v = do
    v' <- getVarAddr v
    tell
      [ lv v A0 v'
      , sv v A0 (RAM SP 0)
      , ADDI SP pSize
      ]
  where
    pSize = varSize v

handleCall :: Maybe Variable -> Label -> Assembly ()
handleCall mvar l = do
    assign <- case mvar of
        Just v -> do
          v' <- addVariable v
          return [sv v V0 v']
        Nothing -> pure []
    tell $ [JAL l] <> assign

handleReturn :: Maybe Variable -> Assembly ()
handleReturn mvar = do
    assign <- case mvar of
        Just v -> do
            v' <- getVarAddr v
            return [lv v V0 v']
        Nothing -> pure []
    retLabel <- getReturnLabel
    tell $ assign <> [B retLabel]

handleJmpZ :: Variable -> Label -> Assembly ()
handleJmpZ v l = do
    v' <- getVarAddr v
    tell
      [ lv v T0 v'
      , BEQ Zero T0 l
      ]

handlePrint :: Variable -> Assembly ()
handlePrint v@(Variable _ vType) = do
    v' <- getVarAddr v
    let prtFn = case vType of
          DInt -> PrintInt
          DChar -> PrintChar
          DString -> PrintString
    tell
      [ lv v T0 v'
      , prtFn T0
      ]


lv :: Variable -> Register -> Address -> ASM
lv (Variable _ vType) = case vType of
    DInt -> LW
    DChar -> LB
    DString -> LW

sv :: Variable -> Register -> Address -> ASM
sv (Variable _ vType) = case vType of
    DInt -> SW
    DChar -> SB
    DString -> SW

varSize :: (Num n) => Variable -> n
varSize = fromIntegral . getTypeSize . varType
