{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}

module VYPe15.Types.Semantics
where

import Prelude (Enum(succ))

import Control.Applicative (Applicative, (<$>))
import Control.Monad (Monad, (>>=))
import Control.Monad.Error.Class (MonadError)
import Control.Monad.Except (ExceptT, runExceptT)
import Control.Monad.State (MonadState, State, evalState, get, modify, state)
import Control.Monad.Writer (MonadWriter, WriterT, runWriterT)
import Data.Either (Either(Left, Right))
import Data.Function (($), (.))
import Data.Functor (Functor)
import Data.List (tail)
import Data.Maybe (Maybe)
import Data.String (IsString)
import Data.Text (Text, unpack)
import Text.Show (Show(show))

import VYPe15.Types.AST (DataType)
import VYPe15.Types.SymbolTable
    (DataId, DataTable, FunctionTable, LabelId, VarId, VariableTable)
import VYPe15.Types.TAC (TAC)

newtype SError
    = SError Text
  deriving (IsString)

instance Show SError where
    show (SError t) = unpack t

data AnalyzerState = AnalyzerState
    { functionTable :: FunctionTable
    , variableTables :: [VariableTable]
    , returnType :: Maybe DataType
    -- ^ Actual return type of function is needed during it's processing so it's
    -- possible to check when type in return statements matches.
    , programData :: DataTable
    , variableId :: VarId
    , dataId :: DataId
    , labelId :: LabelId
    }

newtype SemanticAnalyzer a
    = SemanticAnalyzer { runSemAnalyzer ::
        ExceptT SError (WriterT  [TAC] (State AnalyzerState)) a }
  deriving
    ( Functor
    , Applicative
    , Monad
    , MonadError SError
    , MonadState AnalyzerState
    , MonadWriter [TAC]
    )

evalSemAnalyzer
  :: AnalyzerState
  -> SemanticAnalyzer a
  -> Either SError [TAC]
evalSemAnalyzer s m =
    case (`evalState` s) . runWriterT . runExceptT $ runSemAnalyzer m of
        (Left e, _) -> Left e
        (Right _, w) -> Right w

getVars :: SemanticAnalyzer [VariableTable]
getVars = variableTables <$> get

getFunc :: SemanticAnalyzer FunctionTable
getFunc = functionTable <$> get

getReturnType :: SemanticAnalyzer (Maybe DataType)
getReturnType = returnType <$> get

putVars :: [VariableTable] -> SemanticAnalyzer ()
putVars vars = modify (\s -> s {variableTables = vars})

putFunc :: FunctionTable -> SemanticAnalyzer ()
putFunc func = modify (\s -> s {functionTable = func})

putReturnType :: Maybe DataType -> SemanticAnalyzer ()
putReturnType t = modify (\s -> s {returnType = t})

modifyVars :: ([VariableTable] -> [VariableTable]) -> SemanticAnalyzer ()
modifyVars f = modify
    $ \s -> s {variableTables = f $ variableTables s}

pushVars :: VariableTable -> SemanticAnalyzer ()
pushVars = modifyVars . (:)

popVars :: SemanticAnalyzer ()
popVars = modifyVars tail

modifyFunc :: (FunctionTable -> FunctionTable) -> SemanticAnalyzer ()
modifyFunc f = modify
    $ \s -> s {functionTable = f $ functionTable s}

withVars :: ([VariableTable] -> SemanticAnalyzer a) -> SemanticAnalyzer a
withVars = (getVars >>=)

withFunc :: (FunctionTable -> SemanticAnalyzer a) -> SemanticAnalyzer a
withFunc = (getFunc >>=)

withVars' :: ([VariableTable] -> a) -> SemanticAnalyzer a
withVars' = (<$> getVars)

withFunc' :: (FunctionTable -> a) -> SemanticAnalyzer a
withFunc' = (<$> getFunc)

newVarId :: SemanticAnalyzer VarId
newVarId = state $ \s@AnalyzerState{variableId} ->
    let i = succ variableId in (variableId, s {variableId = i})

newDataId :: SemanticAnalyzer DataId
newDataId = state $ \s@AnalyzerState{dataId} ->
    let i = succ dataId in (dataId, s {dataId = i})

newLabelId :: SemanticAnalyzer LabelId
newLabelId = state $ \s@AnalyzerState{labelId} ->
    let i = succ labelId in (labelId, s {labelId = i})
