{-# Language LambdaCase #-}
{-# Language OverloadedStrings #-}  -- Needed for resolveReference

module Repositories (
    run
) where

import Conduit (runConduit, (.|), sinkList)
import Control.Monad ((<=<))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT)
import Data.Either (fromRight)
import Data.Tagged
import Data.Text (pack, Text)
import Data.Maybe (mapMaybe)
import Git
import Git.Libgit2 (lgFactory, LgRepo)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeFileName)
import System.IO.Error (tryIOError)
import qualified Data.HashMap.Strict as HashMap

import Config (Config, repoPaths, outputDirectory, host)
import Templates (Template, generate)

{-
This is the entrypoint that receives the ``Config`` and uses it to map over our
repositories, reading from them and writing out their web pages using the given
templates.
-}
run :: Config -> [Template] -> IO ()
run config templates = foldMap (processRepo templates config) . repoPaths $ config

----------------------------------------------------------------------------------------

{-
This receives a file path to a single repository and tries to process it. If the
repository doesn't exist or is unreadable in any way we can forget about it and move on
(after informing the user of course).
-}
processRepo :: [Template] -> Config -> FilePath -> IO ()
processRepo templates config path = withRepository lgFactory path $
    processRepo' templates config path

-- This is split out to make type reasoning a bit easier.
processRepo' :: [Template] -> Config -> FilePath -> ReaderT LgRepo IO ()
processRepo' templates config path = do
    liftIO $ createDirectoryIfMissing True outPath
    resolveReference "HEAD" >>= \case
        Nothing -> liftIO . print $ "gitserve: " <> name <> ": Failed to resolve HEAD."
        Just commitID -> do
            let gitHead = Tagged commitID
            -- Variables available in the ginger templates: --

            -- description: The description of the repository from repo/description, if
            -- it exists.
            description <- liftIO $ getDescription $ outPath </> "description"

            -- commits: A list of `Git.Commit` objects to HEAD.
            commits <- getCommits gitHead

            -- tree: A list of `(TreeFilePath, TreeEntry r)` objects at HEAD.
            tree <- getTree gitHead

            -- Run the generator --
            let repo = package config name description commits tree
            liftIO . mapM (generate repo) $ templates
            return ()
  where
    name = takeFileName path
    outPath = outputDirectory config </> name

{-
The role of the function above is to gather information about a git repository and
package it all together in such a way that various parts can be accessed and used by
Ginger templates. `package` takes these pieces of information and places it all into a
hashmap which Ginger can use to look up variables.
-}
package
    :: Config
    -> FilePath
    -> Text
    -> [Commit LgRepo]
    -> [(TreeFilePath, TreeEntry r)]
    -> HashMap.HashMap Text Text
package config name description commits tree = HashMap.fromList
    [ ("host", host config)
    , ("name", pack name)
    , ("description", description)
    , ("commits", "commits")
    , ("tree", "tree")
    ]

getCommits :: CommitOid LgRepo -> ReaderT LgRepo IO [Commit LgRepo]
getCommits commitID =
    sequence . mapMaybe loadCommit <=<
    runConduit $ sourceObjects Nothing commitID False .| sinkList

loadCommit :: ObjectOid LgRepo -> Maybe (ReaderT LgRepo IO (Commit LgRepo))
loadCommit (CommitObjOid oid) = Just $ lookupCommit oid
loadCommit _ = Nothing

getTree :: CommitOid LgRepo -> ReaderT LgRepo IO [(TreeFilePath, TreeEntry LgRepo)]
getTree commitID = lookupCommit commitID >>= lookupTree . commitTree >>= listTreeEntries

getDescription :: FilePath -> IO Text
getDescription path = fromRight "" <$> tryIOError (pack <$> readFile path)
