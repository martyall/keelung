{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}

module Keelung.Monad
  ( Comp,
    runComp,
    Computation (..),
    emptyComputation,
    Elaborated (..),
    Assignment (..),

    -- * Array
    Referable (access, fromArray),
    toArray,
    lengthOf,
    update,
    access2,
    access3,

    -- * Inputs
    input,
    inputNum,
    inputBool,
    inputs,
    inputs2,
    inputs3,

    -- * Statements
    cond,
    assert,
    reduce,
  )
where

import Control.Monad.Except
import Control.Monad.State.Strict hiding (get, put)
import Data.Field.Galois (GaloisField)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Keelung.Error
import Keelung.Field
import Keelung.Syntax
import Keelung.Types
import Prelude hiding (product, sum)

--------------------------------------------------------------------------------

-- | An Assignment associates an expression with a reference
data Assignment t n = Assignment (Ref t) (Val t n)
  deriving (Eq)

instance Show n => Show (Assignment t n) where
  show (Assignment var expr) = show var <> " := " <> show expr

instance Functor (Assignment t) where
  fmap f (Assignment var expr) = Assignment var (fmap f expr)

--------------------------------------------------------------------------------

-- | Data structure for elaboration bookkeeping
data Computation n = Computation
  { -- Counter for generating fresh variables
    compNextVar :: Int,
    -- Counter for allocating fresh heap addresses
    compNextAddr :: Int,
    -- Variables marked as inputs
    compInputVars :: IntSet,
    -- Heap for arrays
    compHeap :: Heap,
    -- Assignments
    compNumAsgns :: [Assignment 'Num n],
    compBoolAsgns :: [Assignment 'Bool n],
    -- Assertions are expressions that are expected to be true
    compAssertions :: [Val 'Bool n]
  }
  deriving (Eq)

emptyComputation :: Computation n
emptyComputation = Computation 0 0 mempty mempty mempty mempty mempty

instance (Show n, GaloisField n, Bounded n, Integral n) => Show (Computation n) where
  show (Computation nextVar nextAddr inputVars _ numAsgns boolAsgns assertions) =
    "{\n  variable counter: " ++ show nextVar
      ++ "\n  address counter: "
      ++ show nextAddr
      ++ "\n  input variables: "
      ++ show (IntSet.toList inputVars)
      ++ "\n  num assignments: "
      ++ show (map (fmap N) numAsgns)
      ++ "\n  bool assignments: "
      ++ show (map (fmap N) boolAsgns)
      ++ "\n  assertions: "
      ++ show (map (fmap N) assertions)
      ++ "\n\
         \}"

--------------------------------------------------------------------------------

-- | The result of elaborating a computation
data Elaborated t n = Elaborated
  { -- | The resulting 'Expr'
    elabVal :: !(Val t n),
    -- | The state of computation after elaboration
    elabComp :: Computation n
  }
  deriving (Eq)

instance (Show n, GaloisField n, Bounded n, Integral n) => Show (Elaborated t n) where
  show (Elaborated expr comp) =
    "{\n expression: "
      ++ show (fmap N expr)
      ++ "\n  compuation state: \n"
      ++ show comp
      ++ "\n}"

--------------------------------------------------------------------------------

-- | The type of a Keelung program
type Comp n = StateT (Computation n) (Except ElabError)

-- | How to run the 'Comp' monad
runComp :: Computation n -> Comp n a -> Either ElabError (a, Computation n)
runComp comp f = runExcept (runStateT f comp)

--------------------------------------------------------------------------------
-- Variable & Input Variable
--------------------------------------------------------------------------------

-- | Allocate a fresh address.
freshVar :: Comp n Var
freshVar = do
  index <- gets compNextVar
  modify (\st -> st {compNextVar = succ index})
  return index

freshAddr :: Comp n Addr
freshAddr = do
  addr <- gets compNextAddr
  modify (\st -> st {compNextAddr = succ addr})
  return addr

--------------------------------------------------------------------------------

-- | Update an entry of an array.
-- When the assigned expression is a variable,
-- we update the entry directly with the variable instead
update :: Referable t => Val ('Arr t) n -> Int -> Val t n -> Comp n ()
update (Ref (Array _ _ addr)) i (Ref (NumVar n)) = writeHeap addr NumElem [(i, n)]
update (Ref (Array _ _ addr)) i (Ref (BoolVar n)) = writeHeap addr BoolElem [(i, n)]
update (Ref (Array elemType _ addr)) i expr = do
  ref <- alloc expr
  writeHeap addr elemType [(i, addrOfRef ref)]

-- | Typeclass for operations on base types
class Proper t where
  -- | Request a fresh input
  input :: Comp n (Val t n)

  -- | Conditional clause
  cond :: Val 'Bool n -> Val t n -> Val t n -> Val t n

instance Proper 'Num where
  input = inputNum
  cond = IfNum

instance Proper 'Bool where
  input = inputBool
  cond = IfBool

-- | Requests a fresh Num input variable
inputNum :: Comp n (Val 'Num n)
inputNum = do
  var <- freshVar
  markVarAsInput var
  return $ Ref $ NumVar var

-- | Requests a fresh Bool input variable
inputBool :: Comp n (Val 'Bool n)
inputBool = do
  var <- freshVar
  markVarAsInput var
  return $ Ref $ BoolVar var

--------------------------------------------------------------------------------
-- Array & Input Array
--------------------------------------------------------------------------------

-- | Converts a list of values to an 1D-array
toArray :: Referable t => [Val t n] -> Comp n (Val ('Arr t) n)
toArray xs = do
  let size = length xs
  when (size == 0) $ throwError EmptyArrayError
  let kind = typeOf (head xs)
  -- allocates fresh variables for each elements
  vars <- mapM alloc xs
  Ref <$> allocateArrayWithVars2 kind vars

--------------------------------------------------------------------------------

-- | Requests a 1D-array of fresh input variables
inputs :: (Proper t, Referable t) => Int -> Comp n (Val ('Arr t) n)
inputs 0 = throwError EmptyArrayError
inputs size = do
  vars <- replicateM size input
  toArray vars

-- | Requests a 2D-array of fresh input variables
inputs2 :: (Proper t, Referable t) => Int -> Int -> Comp n (Val ('Arr ('Arr t)) n)
inputs2 0 _ = throwError EmptyArrayError
inputs2 _ 0 = throwError EmptyArrayError
inputs2 sizeM sizeN = do
  vars <- replicateM sizeM (inputs sizeN)
  toArray vars

-- | Requests a 3D-array of fresh input variables
inputs3 :: (Proper t, Referable t) => Int -> Int -> Int -> Comp n (Val ('Arr ('Arr ('Arr t))) n)
inputs3 0 _ _ = throwError EmptyArrayError
inputs3 _ 0 _ = throwError EmptyArrayError
inputs3 _ _ 0 = throwError EmptyArrayError
inputs3 sizeM sizeN sizeO = do
  vars <- replicateM sizeM (inputs2 sizeN sizeO)
  toArray vars

--------------------------------------------------------------------------------

-- | Typeclass for retrieving the element of an array
class Referable t where
  access :: Val ('Arr t) n -> Int -> Comp n (Val t n)

  -- | Allocates a fresh variable for a value
  alloc :: Val t n -> Comp n (Ref t)

  -- | Convert an array into a list of expressions
  fromArray :: Val ('Arr t) n -> Comp n [Val t n]

  typeOf :: Val t n -> ElemType

instance Referable ref => Referable ('Arr ref) where
  access (Ref (Array elemType _ addr)) i = do
    (elemType', addr') <- readHeap (addr, i)
    -- the element should be an array, we extract the length from its ElemType
    let len' = case elemType' of
          ArrElem _ l -> l
          _ -> error "access: array element is not an array"
    return $ Ref (Array elemType len' addr')

  alloc xs@(Ref (Array elemType len _)) = do
    vars <- forM [0 .. len - 1] $ \i -> do
      x <- access xs i
      alloc x
    allocateArrayWithVars2 elemType vars

  fromArray (Ref (Array _ len addr)) = do
    elems <- forM [0 .. pred len] $ \i -> do
      readHeap (addr, i)

    return $
      map
        ( \(elemType, elemAddr) ->
            case elemType of
              ArrElem l k -> Ref $ Array l k elemAddr
              _ -> error "expecting element to be array"
        )
        elems

  typeOf (Ref (Array elemType len _)) = ArrElem elemType len

instance Referable 'Num where
  access (Ref (Array _ _ addr)) i = Ref . NumVar . snd <$> readHeap (addr, i)

  alloc val = do
    var <- freshVar
    modify' $ \st -> st {compNumAsgns = Assignment (NumVar var) val : compNumAsgns st}
    return $ NumVar var

  fromArray (Ref (Array _ len addr)) = do
    elems <- forM [0 .. pred len] $ \i -> do
      readHeap (addr, i)

    return $
      map
        ( \(elemType, elemAddr) ->
            case elemType of
              NumElem -> Ref $ NumVar elemAddr
              _ -> error "expecting element to be of Num"
        )
        elems

  typeOf _ = NumElem

instance Referable 'Bool where
  access (Ref (Array _ _ addr)) i = Ref . BoolVar . snd <$> readHeap (addr, i)

  alloc val = do
    var <- freshVar
    modify' $ \st -> st {compBoolAsgns = Assignment (BoolVar var) val : compBoolAsgns st}
    return $ BoolVar var

  fromArray (Ref (Array _ len addr)) = do
    elems <- forM [0 .. pred len] $ \i -> do
      readHeap (addr, i)

    return $
      map
        ( \(elemType, elemAddr) ->
            case elemType of
              BoolElem -> Ref $ BoolVar elemAddr
              _ -> error "expecting element to be of Bool"
        )
        elems

  typeOf _ = BoolElem

-- | Access a variable from a 2-D array
access2 :: Referable t => Val ('Arr ('Arr t)) n -> (Int, Int) -> Comp n (Val t n)
access2 addr (i, j) = access addr i >>= flip access j

-- | Access a variable from a 3-D array
access3 :: Referable t => Val ('Arr ('Arr ('Arr t))) n -> (Int, Int, Int) -> Comp n (Val t n)
access3 addr (i, j, k) = access addr i >>= flip access j >>= flip access k

--------------------------------------------------------------------------------

-- | Internal helper function extracting the address of a reference
addrOfRef :: Ref t -> Addr
addrOfRef (BoolVar addr) = addr
addrOfRef (NumVar addr) = addr
addrOfRef (Array _ _ addr) = addr

-- | Internal helper function for allocating an array
-- and associate the address with a set of variables
allocateArrayWithVars2 :: ElemType -> [Ref t] -> Comp n (Ref ('Arr ty))
allocateArrayWithVars2 elemType refs = do
  let size = length refs
  addr <- freshAddr
  writeHeap addr elemType $ zip [0 .. pred size] (map addrOfRef refs)
  return $ Array elemType size addr

-- | Internal helper function for marking a variable as input.
markVarAsInput :: Var -> Comp n ()
markVarAsInput = markVarsAsInput . IntSet.singleton

-- | Internal helper function for marking multiple variables as input
markVarsAsInput :: IntSet -> Comp n ()
markVarsAsInput vars =
  modify (\st -> st {compInputVars = vars <> compInputVars st})

-- | Internal helper function for allocating an array on the heap
writeHeap :: Addr -> ElemType -> [(Int, Var)] -> Comp n ()
writeHeap addr kind array = do
  let bindings = IntMap.fromList array
  heap <- gets compHeap
  let heap' = IntMap.insertWith (<>) addr (kind, bindings) heap
  modify (\st -> st {compHeap = heap'})

-- | Internal helper function for access an array on the heap
readHeap :: (Addr, Int) -> Comp n (ElemType, Int)
readHeap (addr, i) = do
  heap <- gets compHeap
  case IntMap.lookup addr heap of
    Nothing -> error "readHeap: address not found"
    Just (elemType, array) -> case IntMap.lookup i array of
      Nothing -> throwError $ IndexOutOfBoundsError addr i array
      Just n -> return (elemType, n)

--------------------------------------------------------------------------------

-- | An alternative to 'foldM'
reduce :: Foldable m => Val t n -> m a -> (Val t n -> a -> Comp n (Val t n)) -> Comp n (Val t n)
reduce a xs f = foldM f a xs

lengthOf :: Val ('Arr t) n -> Int
lengthOf (Ref (Array _ len _)) = len

--------------------------------------------------------------------------------

-- | Assert that the given expression is true
assert :: Val 'Bool n -> Comp n ()
assert expr = modify' $ \st -> st {compAssertions = expr : compAssertions st}
