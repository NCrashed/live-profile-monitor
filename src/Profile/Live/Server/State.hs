-------------------------------------------------------------------------------
-- |
-- Module      :  Profile.Live.Server.State
-- Copyright   :  (c) Anton Gushcha 2016
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  ncrashed@gmail.com
-- Stability   :  experimental
-- Portability :  portable
--
-- Utilities to watch after eventlog state: alive threads, existing caps and
-- tasks. When new client is connected, we resend relevant events to the remote
-- side. Having relevant state simplifies client work of correct visualization. 
--
------------------------------------------------------------------------------
module Profile.Live.Server.State(

  ) where 

