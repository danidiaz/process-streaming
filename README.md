process-streaming
=================

Exploring how to interact with system processes using a streaming library
(pipes).

The basic goals:

- Concurrent, streaming access to stdin, stdout and stderr.

- Easy integration with regular consumers, parsers from pipes-parse and various
  folds.

- Avoid launching exceptions: use Either or similar solution to signal non-IO
  related error conditions.

Relevant thread in the Haskell Pipes Google Group:

https://groups.google.com/forum/#!searchin/haskell-pipes/pipes$20process/haskell-pipes/JFfyquj5HAg/Lxz7p50JOh4J

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

http://hackage.haskell.org/package/io-streams-1.2.1.2

* process-extras

http://hackage.haskell.org/package/process-extras
