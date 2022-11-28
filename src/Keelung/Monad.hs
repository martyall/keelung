{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Keelung.Monad
  ( Comp,
    runComp,
    Computation (..),
    emptyComputation,
    Elaborated (..),
    Assignment (..),

    -- * Array
    Mutable (updateM),
    toArrayM,
    toArray,
    toArray',
    fromArray,
    fromArrayM,
    freeze,
    freeze2,
    freeze3,
    thaw,
    thaw2,
    thaw3,
    lengthOf,
    accessM,
    accessM2,
    accessM3,
    access,
    access2,
    access3,

    -- * Inputs
    input,
    inputNum,
    inputBool,
    inputUInt,
    inputs,
    inputs2,
    inputs3,

    -- * Statements
    cond,
    assert,
    mapI,
    reduce,
    reuse,
  )
where

import Control.Monad.Except
import Control.Monad.State.Strict hiding (get, put)
import Data.Array ((!))
import Data.Array.Unboxed (Array)
import qualified Data.Array.Unboxed as IArray
import Data.Data (Proxy (..))
import Data.Foldable (toList)
import qualified Data.IntMap.Strict as IntMap
import Data.Traversable (mapAccumL)
import GHC.TypeNats
import Keelung.Error
import Keelung.Syntax
import Keelung.Syntax.Counters
import Keelung.Syntax.VarCounters
import Keelung.Types
import Prelude hiding (product, sum)

--------------------------------------------------------------------------------

-- | An Assignment associates an expression with a reference
data Assignment
  = AssignmentB Var Boolean
  | AssignmentN Var Number
  deriving (Eq)

instance Show Assignment where
  show (AssignmentB var expr) = "$" <> show var <> " := " <> show expr
  show (AssignmentN var expr) = "$" <> show var <> " := " <> show expr

--------------------------------------------------------------------------------

-- | Data structure for elaboration bookkeeping
data Computation = Computation
  { -- Variable bookkeeping
    compVarCounters :: !VarCounters,
    compCounters :: !Counters,
    -- Size of allocated heap addresses
    compAddrSize :: Int,
    -- Heap for arrays
    compHeap :: Heap,
    -- Assignments
    compNumAsgns :: [Assignment],
    compBoolAsgns :: [Assignment],
    -- Assertions are expressions that are expected to be true
    compAssertions :: [Boolean]
  }
  deriving (Eq)

emptyComputation :: Computation
emptyComputation = Computation mempty mempty 0 mempty mempty mempty mempty

instance Show Computation where
  show (Computation varCounters _ addrSize _ numAsgns boolAsgns assertions) =
    "{\n" <> indent (show varCounters)
      <> "  address size: "
      <> show addrSize
      ++ "\n  num assignments: "
      ++ show numAsgns
      ++ "\n  bool assignments: "
      ++ show boolAsgns
      ++ "\n  assertions: "
      ++ show assertions
      ++ "\n\
         \}"

--------------------------------------------------------------------------------

-- | The result of elaborating a computation
data Elaborated t = Elaborated
  { -- | The resulting expression
    elabExpr :: !t,
    -- | The state of computation after elaboration
    elabComp :: Computation
  }
  -- = ElaboratedNum Number Computation
  deriving (Eq)

instance Show t => Show (Elaborated t) where
  show (Elaborated expr comp) =
    "{\n expression: "
      ++ show expr
      ++ "\n  compuation state: \n"
      ++ indent (indent (show comp))
      ++ "\n}"

--------------------------------------------------------------------------------

-- | The type of a Keelung program
type Comp = StateT Computation (Except ElabError)

-- | How to run the 'Comp' monad
runComp :: Computation -> Comp a -> Either ElabError (a, Computation)
runComp comp f = runExcept (runStateT f comp)

modifyCounter :: (Counters -> Counters) -> Comp ()
modifyCounter f = modify (\comp -> comp {compCounters = f (compCounters comp)})

--------------------------------------------------------------------------------
-- Variable & Input Variable
--------------------------------------------------------------------------------

-- | Allocate a fresh Number variable.
freshVarN :: Comp Var
freshVarN = do
  -- counters <- gets compCounters
  -- let index = getCount OfIntermediate OfField counters
  -- modifyCounter $ setCount OfIntermediate OfField (index + 1)

  index <- gets (intermediateVarSize . compVarCounters)
  modify (\st -> st {compVarCounters = bumpIntermediateVar (compVarCounters st)})
  return index

freshVarB :: Comp Var
freshVarB = do
  -- counters <- gets compCounters
  -- let index = getCount OfIntermediate OfBoolean counters
  -- modifyCounter $ setCount OfIntermediate OfBoolean (index + 1)

  index <- gets (intermediateVarSize . compVarCounters)
  modify (\st -> st {compVarCounters = bumpIntermediateVar (compVarCounters st)})
  return index

-- | Allocate a fresh input variable.
freshInputVarN :: Comp Var
freshInputVarN = do
  counters <- gets compCounters
  let index = getCount OfInput OfField counters
  modifyCounter $ addCount OfInput OfField 1
  return index

-- index <- gets (numInputVarSize . compVarCounters)
-- modify (\st -> st {compVarCounters = bumpInputVarN (compVarCounters st)})
-- return index

freshInputVarB :: Comp Var
freshInputVarB = do
  counters <- gets compCounters
  let index = getCount OfInput OfBoolean counters
  modifyCounter $ addCount OfInput OfBoolean 1

  -- index <- gets (boolInputVarSize . compVarCounters)
  -- modify (\st -> st {compVarCounters = bumpInputVarB (compVarCounters st)})
  return index

freshInputVarU :: Int -> Comp Var
freshInputVarU width = do
  counters <- gets compCounters
  let index = getCount OfInput (OfUInt width) counters
  modifyCounter $ addCount OfInput (OfUInt width) 1

  -- index <- gets (customInputSizeOf width . compVarCounters)
  -- modify (\st -> st {compVarCounters = bumpInputVarU width (compVarCounters st)})
  return index

--------------------------------------------------------------------------------

-- | Typeclass for operations on base types
class Proper t where
  -- | Request a fresh input
  input :: Comp t

  -- | Conditional clause
  cond :: Boolean -> t -> t -> t

instance Proper Number where
  input = inputNum
  cond = IfN

instance Proper Boolean where
  input = inputBool
  cond = IfB

instance KnownNat w => Proper (UInt w) where
  input = inputUInt
  cond = IfU

-- | Requests a fresh Num input variable
inputNum :: Comp Number
inputNum = InputVarN <$> freshInputVarN

-- | Requests a fresh Bool input variable
inputBool :: Comp Boolean
inputBool = InputVarB <$> freshInputVarB

-- | Requests a fresh Unsigned integer input variable of some bit width
inputUInt :: forall w. KnownNat w => Comp (UInt w)
inputUInt = InputVarU <$> freshInputVarU width
  where
    width = fromIntegral (natVal (Proxy :: Proxy w))

--------------------------------------------------------------------------------
-- Array & Input Array
--------------------------------------------------------------------------------

-- | Converts a list of values to an 1D-array
toArrayM :: Mutable t => [t] -> Comp (ArrM t)
toArrayM xs = do
  when (null xs) $ throwError EmptyArrayError
  let kind = typeOf (head xs)
  snd <$> allocArray kind xs

-- | Immutable version of `toArray`
toArray :: [t] -> Arr t
toArray xs = Arr $ IArray.listArray (0, length xs - 1) xs

-- | Immutable version of `toArray`
toArray' :: Array Int t -> Arr t
toArray' = Arr

-- | Convert an array into a list of expressions
fromArrayM :: Mutable t => ArrM t -> Comp [t]
fromArrayM ((ArrayRef _ _ addr)) = readHeapArray addr

fromArray :: Arr t -> [t]
fromArray (Arr xs) = toList xs

--------------------------------------------------------------------------------

-- | Requests a 1D-array of fresh input variables
inputs :: Proper t => Int -> Comp (Arr t)
inputs 0 = throwError EmptyArrayError
inputs size = do
  vars <- replicateM size input
  return $ toArray vars

-- | Requests a 2D-array of fresh input variables
inputs2 :: Proper t => Int -> Int -> Comp (Arr (Arr t))
inputs2 0 _ = throwError EmptyArrayError
inputs2 _ 0 = throwError EmptyArrayError
inputs2 sizeM sizeN = do
  vars <- replicateM sizeM (inputs sizeN)
  return $ toArray vars

-- | Requests a 3D-array of fresh input variables
inputs3 :: Proper t => Int -> Int -> Int -> Comp (Arr (Arr (Arr t)))
inputs3 0 _ _ = throwError EmptyArrayError
inputs3 _ 0 _ = throwError EmptyArrayError
inputs3 _ _ 0 = throwError EmptyArrayError
inputs3 sizeM sizeN sizeO = do
  vars <- replicateM sizeM (inputs2 sizeN sizeO)
  return $ toArray vars

--------------------------------------------------------------------------------

-- | Convert a mutable array to an immutable array
freeze :: Mutable t => ArrM t -> Comp (Arr t)
freeze xs = toArray <$> fromArrayM xs

freeze2 :: Mutable t => ArrM (ArrM t) -> Comp (Arr (Arr t))
freeze2 xs = do
  xs' <- fromArrayM xs
  toArray <$> mapM freeze xs'

freeze3 :: Mutable t => ArrM (ArrM (ArrM t)) -> Comp (Arr (Arr (Arr t)))
freeze3 xs = do
  xs' <- fromArrayM xs
  toArray <$> mapM freeze2 xs'

-- | Convert an immutable array to a mutable array
thaw :: Mutable t => Arr t -> Comp (ArrM t)
thaw = toArrayM . toList

thaw2 :: Mutable t => Arr (Arr t) -> Comp (ArrM (ArrM t))
thaw2 xs = mapM thaw (toList xs) >>= toArrayM

thaw3 :: Mutable t => Arr (Arr (Arr t)) -> Comp (ArrM (ArrM (ArrM t)))
thaw3 xs = mapM thaw2 (toList xs) >>= toArrayM

--------------------------------------------------------------------------------

-- | Typeclass for retrieving the element of an array
class Mutable t where
  -- | Allocates a fresh variable for a value
  alloc :: t -> Comp (Var, t)

  typeOf :: t -> ElemType

  -- | Update an entry of an array.
  updateM :: ArrM t -> Int -> t -> Comp ()

  constructElement :: ElemType -> Addr -> t

instance Mutable ref => Mutable (ArrM ref) where
  alloc xs@((ArrayRef elemType len _)) = do
    elements <- mapM (accessM xs) [0 .. len - 1]
    allocArray elemType elements

  typeOf ((ArrayRef elemType len _)) = ArrElem elemType len

  constructElement (ArrElem l k) elemAddr = ArrayRef l k elemAddr
  constructElement _ _ = error "expecting element to be array"

  updateM (ArrayRef elemType _ addr) i expr = do
    (var, _) <- alloc expr
    writeHeap addr elemType (i, var)

instance Mutable Number where
  alloc val = do
    var <- freshVarN
    modify' $ \st -> st {compNumAsgns = AssignmentN var val : compNumAsgns st}
    return (var, VarN var)

  typeOf _ = NumElem

  updateM (ArrayRef _ _ addr) i (VarN n) = writeHeap addr NumElem (i, n)
  updateM (ArrayRef elemType _ addr) i expr = do
    (var, _) <- alloc expr
    writeHeap addr elemType (i, var)

  constructElement NumElem elemAddr = VarN elemAddr
  constructElement _ _ = error "expecting element to be of Num"

instance Mutable Boolean where
  alloc val = do
    var <- freshVarB
    modify' $ \st -> st {compBoolAsgns = AssignmentB var val : compBoolAsgns st}
    return (var, VarB var)

  typeOf _ = BoolElem

  updateM (ArrayRef _ _ addr) i (VarB n) = writeHeap addr BoolElem (i, n)
  updateM (ArrayRef elemType _ addr) i expr = do
    (var, _) <- alloc expr
    writeHeap addr elemType (i, var)

  constructElement BoolElem elemAddr = VarB elemAddr
  constructElement _ _ = error "expecting element to be of Bool"

-- -- | Access an element from a 1-D array
accessM :: Mutable t => ArrM t -> Int -> Comp t
accessM ((ArrayRef _ _ addr)) i = readHeap (addr, i)

-- | Access an element from a 2-D array
accessM2 :: Mutable t => ArrM (ArrM t) -> (Int, Int) -> Comp t
accessM2 addr (i, j) = accessM addr i >>= flip accessM j

-- | Access an element from a 3-D array
accessM3 :: Mutable t => ArrM (ArrM (ArrM t)) -> (Int, Int, Int) -> Comp t
accessM3 addr (i, j, k) = accessM addr i >>= flip accessM j >>= flip accessM k

access :: Arr t -> Int -> t
access (Arr xs) i =
  if i < length xs
    then xs Data.Array.! i
    else error $ show $ IndexOutOfBoundsError2 (length xs) i

-- | Access an element from a 2-D array
access2 :: Arr (Arr t) -> (Int, Int) -> t
access2 addr (i, j) = access (access addr i) j

-- | Access an element from a 3-D array
access3 :: Arr (Arr (Arr t)) -> (Int, Int, Int) -> t
access3 addr (i, j, k) = access (access (access addr i) j) k

--------------------------------------------------------------------------------

-- | Internal helper function for allocating an array with values
allocArray :: Mutable t => ElemType -> [t] -> Comp (Addr, ArrM u)
allocArray elemType vals = do
  -- allocate a new array for holding the variables of these elements
  addr <- gets compAddrSize
  modify (\st -> st {compAddrSize = succ addr})
  -- allocate new variables for each element
  addresses <- map fst <$> mapM alloc vals
  let bindings = IntMap.fromDistinctAscList $ zip [0 ..] addresses
  modifyHeap (IntMap.insert addr (elemType, bindings))
  return (addr, ArrayRef elemType (length vals) addr)

-- | Internal helper function for updating an array entry on the heap
writeHeap :: Addr -> ElemType -> (Int, Var) -> Comp ()
writeHeap addr elemType (index, ref) = do
  let bindings = IntMap.singleton index ref
  modifyHeap (IntMap.insertWith (<>) addr (elemType, bindings))

modifyHeap :: (Heap -> Heap) -> Comp ()
modifyHeap f = do
  heap <- gets compHeap
  let heap' = f heap
  modify (\st -> st {compHeap = heap'})

-- | Internal helper function for accessing an element of an array on the heap
readHeap :: Mutable t => (Addr, Int) -> Comp t
readHeap (addr, i) = do
  heap <- gets compHeap
  case IntMap.lookup addr heap of
    Nothing -> error "readHeap: address not found"
    Just (elemType, array) -> case IntMap.lookup i array of
      Nothing -> throwError $ IndexOutOfBoundsError addr i array
      Just var -> return $ constructElement elemType var

-- | Internal helper function for accessing an array on the heap
readHeapArray :: Mutable t => Addr -> Comp [t]
readHeapArray addr = do
  heap <- gets compHeap
  case IntMap.lookup addr heap of
    Nothing -> error "readHeap: address not found"
    Just (elemType, array) -> return $ map (constructElement elemType) (IntMap.elems array)

--------------------------------------------------------------------------------

-- | An alternative to 'foldM'
reduce :: Foldable m => t -> m a -> (t -> a -> Comp t) -> Comp t
reduce a xs f = foldM f a xs

-- | Map with index, basically 'mapi' in OCaml.
mapI :: Traversable f => (Int -> a -> b) -> f a -> f b
mapI f = snd . mapAccumL (\i x -> (i + 1, f i x)) 0

-- | Length of a mutable array
lengthOf :: ArrM t -> Int
lengthOf ((ArrayRef _ len _)) = len

--------------------------------------------------------------------------------

-- | Assert that the given expression is true
assert :: Boolean -> Comp ()
assert expr = modify' $ \st -> st {compAssertions = expr : compAssertions st}

--------------------------------------------------------------------------------

-- | Allow an expression to be referenced and reused in the future
class Reusable t where
  reuse :: t -> Comp t

instance Reusable Boolean where
  reuse val = do
    xs <- toArrayM [val]
    accessM xs 0

instance Reusable Number where
  reuse val = do
    xs <- toArrayM [val]
    accessM xs 0

instance Mutable t => Reusable (ArrM t) where
  reuse val = do
    xs <- toArrayM [val]
    accessM xs 0

instance Mutable t => Reusable (Arr t) where
  reuse arr = thaw arr >>= reuse >>= freeze