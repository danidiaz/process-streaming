process-streaming
=================

A library for interacting with system processes in a streaming fashion.

The basic goals:

- Concurrent, streaming access to stdin, stdout and stderr...

- ...all the while preventing deadlocks caused by mishandling of the streams. 

- Easy integration with consumers from
  [pipes](http://hackage.haskell.org/package/pipes), parsers from
  [pipes-parse](http://hackage.haskell.org/package/pipes-parse) and folds from
  [foldl](http://hackage.haskell.org/package/foldl).

- Facilitate the use of sum types to signal failures, when desired.

- No fussing around with process handles: wait for the process by waiting for
  the IO action, terminate the process by killing the thread executing the IO
  action.

A [relevant thread](https://groups.google.com/forum/#!searchin/haskell-pipes/pipes$20process/haskell-pipes/JFfyquj5HAg/Lxz7p50JOh4J) in the Haskell Pipes Google Group.


## Possible alternatives in Hackage

* turtle (pipes-based, shell programming)

http://hackage.haskell.org/package/turtle

* pipes-cliff (pipes-based)

http://hackage.haskell.org/package/pipes-cliff

* pipes-shell (pipes-based)

http://hackage.haskell.org/package/pipes-shell

* shelly (shell programming)

http://hackage.haskell.org/package/shelly

* shell-conduit (coundit-based, shell programming)

http://hackage.haskell.org/package/shell-conduit

* Data.Conduit.Process from conduit-extra (conduit-based)

http://hackage.haskell.org/package/conduit-extra

* System.IO.Streams.Process from io-streams (iostreams-based)

http://hackage.haskell.org/package/io-streams

* process-extras

http://hackage.haskell.org/package/process-extras
