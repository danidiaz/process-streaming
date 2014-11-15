module Main where

import Control.Applicative
import Control.Monad
import Data.List
import System.Directory
import System.FilePath
import Test.DocTest

main :: IO ()
main = doctest ["src/System/Process/Streaming/Tutorial.hs"]
