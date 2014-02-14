process-streaming
=================

Exploring how to interact with system processes using a streaming library
(pipes).

The basic goals:

- Concurrent, buffered, streaming access to stdin, stdout and stderr.

- Easy integration with parsers pipes-parse package and folds from
  Pipes.Prelude.

- Avoid launching exceptions: use Either or similar solution to signal error
  conditions.

- Avoid deadlock scenarios caused by full output buffers.

- Modularity: don't enforce a "pipeified" approach for all the handles, let the
  user "pipeify" only the particular handles in which he is interested. 

Relevant thread in the Haskell Pipes Google Group:

https://groups.google.com/forum/#!searchin/haskell-pipes/pipes$20process/haskell-pipes/JFfyquj5HAg/Lxz7p50JOh4J
