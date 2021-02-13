module TestB (foo) where

{- $setup
>>> :set -XTypeApplications
-}

-- | Example usage:
--
-- >>> foo @Int
-- 3
foo :: Num a => a
foo = 3
