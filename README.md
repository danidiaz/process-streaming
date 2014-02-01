process-pipes
=============

Exploring how to interact with system processes using pipes.

Three basic goals:

- Streaming access to *both* stdin and stdout, in a manner easy to integrate with
  pipes-parse.

- Never ever launch an exception: always use ErrorT or similar solution.

- Avoid deadlock scenarios caused by full output buffers.

Relevant thread in the Haskell Pipes Google group:

https://groups.google.com/forum/#!searchin/haskell-pipes/pipes$20process/haskell-pipes/JFfyquj5HAg/Lxz7p50JOh4J
