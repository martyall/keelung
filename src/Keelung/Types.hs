{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
module Keelung.Types where 
import Data.IntMap (IntMap)
import GHC.Generics (Generic)
import Data.Serialize (Serialize)
import Data.Kind (Type)

--------------------------------------------------------------------------------

-- | A "Variable" is just a integer.
type Var = Int

-- | An "Address" is also just a integer.
type Addr = Int

--------------------------------------------------------------------------------

-- | A Heap is an mapping of mappings of variables
type Heap =
  IntMap
    ( ElemType, -- kind of element
      IntMap Int -- mapping of index to address of element variables 
    )

-- | Type of elements of a array 
data ElemType
  = NumElem -- Field numbers
  | BoolElem -- Booleans
  | ArrElem ElemType Int -- Arrays
  deriving (Show, Eq, Generic)

instance Serialize ElemType

instance Semigroup ElemType where
  a <> b = case (a, b) of
    (NumElem, NumElem) -> NumElem
    (BoolElem, BoolElem) -> BoolElem
    (ArrElem a' l, ArrElem b' _) -> ArrElem (a' <> b') l
    _ -> error "ElemType must be the same"

--------------------------------------------------------------------------------

-- | Data kind for annotating the type of expressions.
data Kind
  = Num -- Field numbers
  | Bool -- Booleans
  | Unit -- Unit
  | Arr Kind -- Arrays
  deriving (Show, Eq)

--------------------------------------------------------------------------------

-- | References to variables or arrays
data Ref :: Kind -> Type where
  BoolVar :: Var -> Ref 'Bool
  NumVar :: Var -> Ref 'Num
  Array :: ElemType -> Int -> Addr -> Ref ('Arr val)

-- | 2 references are equal if they refer to the same variable or array
instance Eq (Ref kind) where
  BoolVar i == BoolVar j = i == j
  NumVar i == NumVar j = i == j
  Array _ _ addr == Array _ _ addr' = addr == addr'

instance Show (Ref ref) where
  show (BoolVar v) = "$B" ++ show v
  show (NumVar v) = "$N" ++ show v
  show (Array _ n a) = "$A" ++ show n ++ ":" ++ show a