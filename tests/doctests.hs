module Main where

import Test.DocTest

main :: IO ()
main = doctest [
            "src/System/Process/Streaming.hs",
            "src/System/Process/Streaming/Text.hs"
            ]
