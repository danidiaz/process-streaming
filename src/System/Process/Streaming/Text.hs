{-| 
    This module re-exports the entirety of "Pipes.Transduce.Text" from the
@pipes-transduce@ package. It provides functions useful for treating the
@stdout@ and @stderr@ streams as text.
   
    It is better to import it qualified:
 
>>> import qualified System.Process.Streaming.Text as PT

-}
module System.Process.Streaming.Text ( 
        -- * Examples
        -- $examples
        module Pipes.Transduce.Text
    ) where

import Pipes.Transduce.Text

{- $setup

>>> :set -XOverloadedStrings
>>> import qualified Data.Text.Lazy
>>> import qualified Pipes
>>> import Pipes.Transduce
>>> import Control.Applicative
>>> import System.Process.Streaming
>>> import qualified System.Process.Streaming.Text as PT
>>> import qualified Control.Foldl as L

-}

{- $examples

   To process a standard stream as utf8 text:

>>> execute (piped (shell "echo foo")) (foldOut (PT.asUtf8x PT.intoLazyText))
"foo\n"   

   'Pipes.Transduce.Text.asUtf8x' throws exceptions on decodign errors.
   'Pipes.Transduce.Text.asUtf8' uses sum types instead. We must provide an
   error mapping function, here we simply use 'id':

>>> executeFallibly (piped (shell "echo foo")) (foldOut (PT.asUtf8 id PT.intoLazyText))
Right "foo\n"   
   
   'Pipes.Transduce.Text.asFoldedLines' lets you identify and consume the lines that appear in a
   stream as lazy 'Data.Text.Lazy.Text's.

>>> :{ 
      execute (piped (shell "{ echo foo ; echo bar ; }")) $
          (foldOut (PT.asUtf8x (PT.asFoldedLines intoList)))
    :}
["foo","bar"]

    Sometimes we want to consume the lines in @stdout@ and @stderr@ as a single
    text stream. We can do this with 'System.Process.Streaming.foldOutErr' and
    'Pipes.Transduce.Text.combinedLines'.

    We also need 'Pipes.Transduce.Text.bothAsUtf8x' to decode both streams.

>>> :{ 
      execute (piped (shell "{ echo ooo ; sleep 1 ; echo eee 1>&2 ; }")) $ 
          (foldOutErr (PT.bothAsUtf8x (PT.combinedLines PT.intoLazyText)))
    :}
"ooo\neee\n"

    We can also tag each line with its provenance, using
    'Pipes.Transduce.Text.combinedLinesPrefixing':

>>> :{ 
      execute (piped (shell "{ echo ooo ; sleep 1 ; echo eee 1>&2 ; }")) $
          (foldOutErr (PT.bothAsUtf8x (PT.combinedLinesPrefixing "+" "-" PT.intoLazyText)))
    :}
"+ooo\n-eee\n"

-}

 

