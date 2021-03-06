{-# LANGUAGE DeriveFoldable, DeriveGeneric, DeriveTraversable #-}
-- | A list of entities with relative frequencies of appearance.
module Game.LambdaHack.Common.Frequency
  ( -- * The @Frequency@ type
    Frequency
    -- * Construction
  , uniformFreq, toFreq
    -- * Transformation
  , scaleFreq, renameFreq, setFreq
    -- * Consumption
  , nullFreq, runFrequency, nameFrequency
  , minFreq, maxFreq, mostFreq
  ) where

import Prelude ()

import Game.LambdaHack.Common.Prelude

import Control.Applicative
import Data.Int (Int32)
import Data.Ord (comparing)
import GHC.Generics (Generic)

-- | The frequency distribution type. Not normalized (operations may
-- or may not group the same elements and sum their frequencies).
-- However, elements with zero frequency are removed upon construction.
--
-- The @Eq@ instance compares raw representations, not relative,
-- normalized frequencies, so operations don't need to preserve
-- the expected equalities.
data Frequency a = Frequency
  { runFrequency  :: [(Int, a)]  -- ^ give acces to raw frequency values
  , nameFrequency :: Text        -- ^ short description for debug, etc.
  }
  deriving (Show, Eq, Ord, Foldable, Traversable, Generic)

_maxBound32 :: Integer
_maxBound32 = toInteger (maxBound :: Int32)

instance Monad Frequency where
  Frequency xs name >>= f =
    Frequency [
#ifdef WITH_EXPENSIVE_ASSERTIONS
                assert (toInteger p * toInteger q <= _maxBound32)
#endif
                (p * q, y)
              | (p, x) <- xs
              , (q, y) <- runFrequency (f x)
              ]
              ("bind (" <> name <> ")")

instance Functor Frequency where
  fmap f (Frequency xs name) = Frequency (map (second f) xs) name

instance Applicative Frequency where
  {-# INLINE pure #-}
  pure x = Frequency [(1, x)] "pure"
  Frequency fs fname <*> Frequency ys yname =
    Frequency [
#ifdef WITH_EXPENSIVE_ASSERTIONS
                assert (toInteger p * toInteger q <= _maxBound32)
#endif
                (p * q, f y)
              | (p, f) <- fs
              , (q, y) <- ys
              ]
              ("(" <> fname <> ") <*> (" <> yname <> ")")

instance MonadPlus Frequency where
  mplus (Frequency xs xname) (Frequency ys yname) =
    let name = case (xs, ys) of
          ([], []) -> "[]"
          ([], _ ) -> yname
          (_,  []) -> xname
          _ -> "(" <> xname <> ") ++ (" <> yname <> ")"
    in Frequency (xs ++ ys) name
  mzero = Frequency [] "[]"

instance Alternative Frequency where
  (<|>) = mplus
  empty = mzero

-- | Uniform discrete frequency distribution.
uniformFreq :: Text -> [a] -> Frequency a
uniformFreq name l = Frequency (map (\x -> (1, x)) l) name

-- | Takes a name and a list of frequencies and items
-- into the frequency distribution.
toFreq :: Text -> [(Int, a)] -> Frequency a
toFreq name l =
#ifdef WITH_EXPENSIVE_ASSERTIONS
  assert (all (\(p, _) -> toInteger p <= _maxBound32) l) $
#endif
  Frequency (filter ((> 0 ) . fst) l) name

-- | Scale frequency distribution, multiplying it
-- by a positive integer constant.
scaleFreq :: Show a => Int -> Frequency a -> Frequency a
scaleFreq n (Frequency xs name) =
  assert (n > 0 `blame` "non-positive frequency scale" `swith` (name, n, xs)) $
  let multN p =
#ifdef WITH_EXPENSIVE_ASSERTIONS
                assert (toInteger p * toInteger n <= _maxBound32) $
#endif
                p * n
  in Frequency (map (first multN) xs) name

-- | Change the description of the frequency.
renameFreq :: Text -> Frequency a -> Frequency a
renameFreq newName fr = fr {nameFrequency = newName}

-- | Set frequency of an element.
setFreq :: Eq a => Frequency a -> a -> Int -> Frequency a
setFreq (Frequency xs name) x n =
  let xsNew = [(n, x) | n <= 0] ++ filter ((/= x) . snd) xs
  in Frequency xsNew name

-- | Test if the frequency distribution is empty.
nullFreq :: Frequency a -> Bool
nullFreq (Frequency fs _) = null fs

minFreq :: Ord a => Frequency a -> Maybe a
minFreq fr = if nullFreq fr then Nothing else Just $ minimum fr

maxFreq :: Ord a => Frequency a -> Maybe a
maxFreq fr = if nullFreq fr then Nothing else Just $ maximum fr

mostFreq :: Frequency a -> Maybe a
mostFreq fr = if nullFreq fr then Nothing
              else Just $ snd $ maximumBy (comparing fst) $ runFrequency fr
