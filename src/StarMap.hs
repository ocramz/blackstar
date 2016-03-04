{-# LANGUAGE BangPatterns, DeriveGeneric, TypeSynonymInstances,
             FlexibleInstances #-}

module StarMap
    ( Star, StarTree, readMapFromFile, buildStarTree, sqrnorm, starLookup
    ) where

import Control.Monad
import Data.Word
import Data.Char
import qualified Data.ByteString as B
import Data.Serialize
import Data.Serialize.Get
import Data.Serialize.IEEE754
import Data.KdMap.Static
import Linear
import qualified Vision.Image as I

import Color

type Star = (V3 Double, (Int, Word8, Word8))
type StarTree = KdMap Double (V3 Double) (Int, Word8, Word8)

instance Serialize StarTree

instance Serialize (V3 Double -> V3 Double -> Double) where
    put _ = put ""
    get = return (defaultSqrDist v3AsList)

instance Serialize (V3 Double -> [Double]) where
    put _ = put ""
    get = return v3AsList

-- Parse the star list in the binary format specified at
-- http://tdc-www.harvard.edu/software/catalogs/ppm.entry.html
readMap :: Get [Star]
readMap = do
    -- Skip the header
    skip 28
    nBytes <- remaining
    replicateM (nBytes `div` 28) $ do
        ra <- getFloat64be
        dec <- getFloat64be
        spectral <- getWord8
        skip 1
        mag <- getInt16be
        skip 8
        return $ (raDecToCartesian ra dec, starColor' (fromIntegral mag)
                 . chr $ fromIntegral spectral)

starColor' :: Int -> Char -> (Int, Word8, Word8)
starColor' !mag !ch = let (!h, !s) = starColor ch in (mag, h, s)

-- Some nice colour values for different spectral types
starColor :: Char -> (Word8, Word8)
starColor 'O' = (114, 99)
starColor 'B' = (113, 84)
starColor 'A' = (112, 54)
starColor 'F' = (117, 8)
starColor 'G' = (16, 23)
starColor 'K' = (17, 74)
starColor 'M' = (17, 143)
starColor _   = (0, 0)

raDecToCartesian :: Double -> Double -> V3 Double
raDecToCartesian ra dec = V3 (cos dec*cos ra) (cos dec*sin ra) (sin dec)

readMapFromFile :: FilePath -> IO (Either String [Star])
readMapFromFile path = do
    bs <- B.readFile path
    return $ runGet readMap bs

buildStarTree :: [Star] -> StarTree
buildStarTree stars = build v3AsList stars

v3AsList :: V3 Double -> [Double]
v3AsList (V3 !x !y !z) = [x, y, z]

sqrnorm :: V3 Double -> Double
sqrnorm (V3 !x !y !z) = x*x + y*y + z*z

starLookup :: StarTree -> Double -> Double -> V3 Double -> Rgba
starLookup !starmap !intensity !saturation !vel = let
        r = 0.002  -- star sampling radius
        m0 = 1350 :: Double  -- the "minimum visible" magnitude
        m1 = 930 :: Double  -- the "saturated" magnitude
        w = 0.0005  -- width parameter of the gaussian function
        nvel = normalize vel
        d2 = sqrnorm $ pos ^-^ nvel  -- the distance from the star on the
                                     -- celestial sphere surface
        a = log (intensity * 255) / (m0 - m1)
        (pos, (mag, hue, sat)) = nearest starmap nvel
        -- Conversion from the log magnitude scale to linear brightness
        -- and a Gaussian intensity function. This determines the apparent size
        -- and brightness of the star.
        val = floor . max 0 . min (intensity * 255)
              . exp $ a*(m0 - fromIntegral mag) - d2/(2*w**2)
    in if d2 < r*r then fromRGBPixel . I.convert $ I.HSVPixel hue
                       (floor $ saturation * fromIntegral sat) val
                   else Rgba 0 0 0 1
