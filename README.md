process-streaming
=================

Exploring how to interact with system processes using pipes.

Three basic goals:

- Concurrent streaming access to both stdout and stderr, in a manner easy to
  integrate with pipes-parse.

- Avoid launching exceptions: always use ErrorT or similar solution to signal
  error conditions.

- Avoid deadlock scenarios caused by full output buffers.

Relevant thread in the Haskell Pipes Google Group:

https://groups.google.com/forum/#!searchin/haskell-pipes/pipes$20process/haskell-pipes/JFfyquj5HAg/Lxz7p50JOh4J
