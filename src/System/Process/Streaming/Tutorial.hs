
-- |
-- This module contains helper functions and types built on top of
-- "System.Process" and "Pipes".
--
-- They provide concurrent, streaming access to the inputs and outputs of
-- system processes.
--
-- Error conditions not directly related to IO are made explicit
-- in the types.
--
-- Regular 'Consumer's, 'Parser's from @pipes-parse@ and various folds can
-- be used to consume the output streams of the external processes.
--
-----------------------------------------------------------------------------

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module System.Process.Streaming.Tutorial ( 
    ) where


