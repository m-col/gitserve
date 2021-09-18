{-# Language OverloadedStrings #-}  -- Needed for resolvReference

module Repositories (
    run
) where

import Control.Monad.IO.Class (liftIO)
import Data.Foldable (foldMap)
import Data.Tagged
import Git
import Git.Libgit2 (lgFactory)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeFileName)
import Text.Ginger (easyRender)

import Config (Config, repoPaths, outputDirectory)
import Templates (Template, templateGinger, templatePath)

{-
This is the entrypoint that receives the ``Config`` and uses it to map over our
repositories, reading from them and writing out their web pages using the given
templates.
-}
run :: Config -> [Template] -> IO ()
run config templates = foldMap (processRepo templates $ outputDirectory config) . repoPaths $ config

----------------------------------------------------------------------------------------

{-
This receives a file path to a single repository and tries to process it. If the
repository doesn't exist or is unreadable in any way we can forget about it and move on
(after informing the user of course).
-}
processRepo :: [Template] -> FilePath -> FilePath -> IO ()
processRepo templates outputDirectory path = withRepository lgFactory path $ do
    return $ createDirectoryIfMissing True outPath
    maybeObjID <- resolveReference "HEAD"
    case maybeObjID of
        Just commitID -> do
            headCommit <- lookupCommit (Tagged commitID)
            liftIO $ print $ commitLog headCommit
        _ -> liftIO $ print $ "gitserve: " <> (takeFileName path) <> ": Failed to resolve HEAD."
  where
    outPath = outputDirectory </> (takeFileName path)

-- Variables:
title = "gitserve"
description = ""
host = "http://localhost"
path = ""
