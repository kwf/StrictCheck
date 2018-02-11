{-# language PartialTypeSignatures #-}
{-# OPTIONS_GHC -fno-warn-partial-type-signatures #-}
module Test.StrictCheck.Observe where

import Control.DeepSeq
import Data.Bifunctor
import Control.Monad.Identity
import Data.Functor.Product
import Data.Monoid ( Endo(..) )

import Data.IORef
import System.IO.Unsafe

import qualified GHC.Generics as GHC
import Generics.SOP

import Test.StrictCheck.Curry
import Test.StrictCheck.Shaped
import Test.StrictCheck.Shaped.Flattened

--------------------------------------------------------
-- The basic types which make up a demand description --
--------------------------------------------------------

data Thunk a = E !a | T
  deriving (Eq, Ord, Show, Functor, GHC.Generic, NFData)

type Demand = (%) Thunk


------------------------------------------------------
-- Observing demand behavior of arbitrary functions --
------------------------------------------------------

-- | Force a value in some applicative context. This is useful for ensuring that
-- values are evaluated in the correct order inside of unsafePerformIO blocks.
evaluate :: Applicative f => a -> f ()
evaluate !_ = pure ()

{-# NOINLINE entangle #-}
entangle :: forall a. a -> (a, Thunk a)
entangle a =
  unsafePerformIO $ do
    ref <- newIORef T
    return ( unsafePerformIO $ do
               writeIORef ref (E a)
               return a
           , unsafePerformIO $ readIORef ref )

{-# NOINLINE entangleShape #-}
entangleShape :: Shaped a => a -> (a, Thunk % a)
entangleShape =
  first (fuse unI)
  . (\(Pair l r) -> (l, r))
  . separate (uncurry Pair . first I . entangle . unI)
  . interleave I

observe1 :: (Shaped a, Shaped b, _)
         => (b -> ()) -> (a -> b) -> a -> (Demand b, Demand a)
observe1 context function input =
  runIdentity $ do
    let (input',  inputD)  = entangleShape input
        (result', resultD) = entangleShape (function input')
    !_ <- evaluate (context result')
    !_ <- evaluate (rnf inputD)
    !_ <- evaluate (rnf resultD)
    return (resultD, inputD)

observeNP :: (All Shaped inputs, Shaped result, _)
          => (result -> ())
          -> (NP I inputs -> result)
          -> NP I inputs
          -> ( Demand result
             , NP Demand inputs )
observeNP context function inputs =
  runIdentity $ do
    let entangled =
          hcliftA (Proxy :: Proxy Shaped)
                  (uncurry Pair . first I . entangleShape . unI) inputs
        (inputs', inputsD) =
          (hliftA (\(Pair r _) -> r) entangled,
           hliftA (\(Pair _ l) -> l) entangled)
        (result', resultD) = entangleShape (function inputs')
    !_ <- evaluate (context result')
    !_ <- evaluate (rnf inputsD)
    !_ <- evaluate (rnf resultD)
    return (resultD, inputsD)

observe :: (All Shaped (Args function), Shaped (Result function), _)
        => (Result function -> ())
        -> function
        -> Args function
        ⋯-> ( Demand (Result function)
             , NP Demand (Args function) )
observe context function =
  curryAll (observeNP context (uncurryAll function))


---------------
-- Shrinking --
---------------

shrinkDemand :: forall a. Shaped a => Demand a -> [Demand a]
shrinkDemand (Wrap T)     = []
shrinkDemand (Wrap (E d)) =
  match @a d d $ \(Flattened un flat) _ ->
    case shrinkOne flat of
      [] -> [Wrap T]
      xs -> fmap (Wrap . E . un) xs
  where
    shrinkOne :: All Shaped xs => NP Demand xs -> [NP Demand xs]
    shrinkOne Nil = []
    shrinkOne (Wrap T :* xs) =
      (Wrap T :*) <$> shrinkOne xs
    shrinkOne (f@(Wrap (E _)) :* xs) =
      fmap (:* xs) (shrinkDemand f) ++ fmap (f :* ) (shrinkOne xs)


-----------------------------
-- Pretty-printing demands --
-----------------------------

showPrettyFieldThunkS
  :: Bool -> String -> Int -> Rendered Thunk -> String -> String
showPrettyFieldThunkS _            thunk _    (RWrap T)      = (thunk ++)
showPrettyFieldThunkS qualifyNames thunk prec (RWrap (E pd)) =
  case pd of
    ConstructorD name fields ->
      showParen (prec > 10 && length fields > 0) $
        showString (qualify name)
        . flip foldMapCompose fields
          (((' ' :) .) . showPrettyFieldThunkS qualifyNames thunk 11)
    RecordD name recfields ->
      showParen (prec > 10) $
        showString (qualify name)
        . flip foldMapCompose recfields
          (\(fName, x) ->
             ((((" " ++ qualify fName ++ " = ") ++) .) $
             showPrettyFieldThunkS qualifyNames thunk 11 x))
    InfixD name assoc fixity l r ->
      showParen (prec > fixity) $
        let (lprec, rprec) =
              case assoc of
                LeftAssociative  -> (fixity,     fixity + 1)
                RightAssociative -> (fixity + 1, fixity)
                NotAssociative   -> (fixity + 1, fixity + 1)
        in showPrettyFieldThunkS qualifyNames thunk lprec l
         . showString (" " ++ qualify name ++ " ")
         . showPrettyFieldThunkS qualifyNames thunk rprec r
    CustomD fixity list ->
      showParen (prec > fixity) $
        foldr (.) id $ flip fmap list $
          extractEither
          . bimap (showString . qualifyEither)
                  (\(f, pf) -> showPrettyFieldThunkS qualifyNames thunk f pf)
  where
    qualify (m, _, n) =
      if qualifyNames then (m ++ "." ++ n) else n

    qualifyEither (Left s) = s
    qualifyEither (Right (m, n)) =
      if qualifyNames then (m ++ "." ++ n) else n

    extractEither (Left x)  = x
    extractEither (Right x) = x

    foldMapCompose :: (a -> (b -> b)) -> [a] -> (b -> b)
    foldMapCompose f = appEndo . foldMap (Endo . f)

-- This precedence-aware pretty-printing algorithm is adapted from a solution
-- given by Brian Huffman on StackOverflow:
-- https://stackoverflow.com/questions/27471937/43639618#43639618


prettyDemand :: Shaped a => Demand a -> String
prettyDemand d =
  showPrettyFieldThunkS False "_" 10 (renderfold d) ""

printDemand :: Shaped a => Demand a -> IO ()
printDemand = putStrLn . prettyDemand
