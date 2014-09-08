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
