{-| 
    This module re-exports functions useful for treating the @stdout@ and @stderr@
    streams as text.
   
    It is better to import it qualified:
 
>>> import qualified System.Process.Streaming.Text as PT

-}
module System.Process.Streaming.Text ( 
        -- * Examples
        -- $examples
        -- * Re-exports
        -- $reexports
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

   To process a standard stream as text, use the 'utf8' or 'utf8x'
   'Transducer's, applying them with 'transduce1' to a 'Fold1' that accepts
   text. 
   
   The result will be a a 'Fold1' that accepts raw 'ByteStrings':

>>> execute (piped (shell "echo foo")) (foldOut (transduce1 PT.utf8x PT.intoLazyText))
"foo\n"   

   The difference between 'utf8' and 'utf8x' is that the former uses an 'Either'
   to signal encoding errors, while the latter uses an exception.

>>> executeFallibly (piped (shell "echo foo")) (foldOut (transduce1 PT.utf8 PT.intoLazyText))
Right "foo\n"   
   
   'foldedLines' lets you consume the lines that appear in a stream as lazy
   'Data.Text.Lazy.Text's. Here we collect them in a list using the
   'Control.Foldl.list' 'Control.Foldl.Fold' from the @foldl@ package:

>>> :{ 
      execute (piped (shell "{ echo foo ; echo bar ; }"))
    . foldOut
    . transduce1 PT.utf8x 
    . transduce1 PT.foldedLines 
    $ withFold L.list
    :}
["foo","bar"]

    Sometimes we want to consume the lines in @stdout@ and @stderr@ as a single
    stream. We can do this with 'System.Process.Streaming.foldOutErr' and the 'Pipes.Transduce.combined' function.

    'combined' takes one 'Pipes.Transduce.Transducer' for @stdout@ and another
    for @stderr@, that known how to decode each stream into text, then break
    the text into lines.  
    
    The resulting lines are consumed using a 'Fold1': 

>>> :{ 
      execute (piped (shell "{ echo ooo ; sleep 1 ; echo eee 1>&2 ; }"))  
    . foldOutErr
    . combined (PT.lines PT.utf8x) (PT.lines PT.utf8x)
    $ intoLazyText
    :}
"ooo\neee\n"

    We can also tag each line with its provenance, using 'Pipes.Transduce.groups':

>>> :{ 
    let tag prefix = groups (\producer -> Pipes.yield prefix *> producer)
    in
      execute (piped (shell "{ echo ooo ; sleep 1 ; echo eee 1>&2 ; }"))  
    . foldOutErr
    . combined (tag "+" (PT.lines PT.utf8x)) (tag "-" (PT.lines PT.utf8x))
    $ intoLazyText
    :}
"+ooo\n-eee\n"

-}

{- $reexports
 
"Pipes.Transduce.Text" from the @pipes-transduce@ package is re-exported in its entirety.

-} 

