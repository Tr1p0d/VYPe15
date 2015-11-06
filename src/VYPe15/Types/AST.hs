{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NoImplicitPrelude #-}

module VYPe15.Types.AST
where

import Data.Char (Char)
import Data.Eq (Eq)
import Data.Int (Int32)
import Data.Maybe (Maybe)
import Data.Ord (Ord)
import Data.String (IsString(fromString), String)
import Text.Show (Show(show))

type Program
  = [FunDeclrOrDef]

data FunDeclrOrDef
  = FunDeclr (Maybe DataType) Identifier (Maybe [Param])
  | FunDef (Maybe DataType) Identifier (Maybe [Param]) [Stat]
  deriving (Show)

data Identifier
  = Identifier { getId :: String }
  deriving (Show, Ord, Eq)

instance IsString Identifier where
  fromString = Identifier

data Stat
  = Assign Identifier Exp
  | If Exp [Stat] [Stat]
  | Return (Maybe Exp)
  | While Exp [Stat]
  | VarDef DataType [Identifier]
  | FuncCall Identifier [Exp]
  deriving (Show)

data Exp
  = OR Exp Exp
  | AND Exp Exp
  | Eq Exp Exp
  | NonEq Exp Exp
  | Less Exp Exp
  | Greater Exp Exp
  | LessEq Exp Exp
  | GreaterEq Exp Exp
  | Plus Exp Exp
  | Minus Exp Exp
  | Times Exp Exp
  | Div Exp Exp
  | Mod Exp Exp
  | NOT Exp
  | Cast DataType Exp
  | ConsNum Int32
  | ConsString String
  | ConsChar Char
  | FuncCallExp Identifier [Exp]
  | IdentifierExp String
  deriving (Show)

data DataType
  = DInt
  | DChar
  | DString
  deriving (Eq)

instance Show DataType where
    show DInt = "int"
    show DChar = "char"
    show DString = "string"

data Param
    = Param DataType Identifier
    | AnonymousParam DataType
    deriving (Show)

getParamType :: Param -> DataType
getParamType = \case
    (Param t _) -> t
    (AnonymousParam t) -> t
