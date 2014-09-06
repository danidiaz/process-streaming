import Test.Tasty
import Test.Tasty.HUnit

main = defaultMain tests

tests :: TestTree
tests = testGroup "Tests" []
--tests = testGroup "Tests" [properties, unitTests]

