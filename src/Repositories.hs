{-# Language LambdaCase #-}
{-# Language OverloadedStrings #-}
{-# Language FlexibleInstances #-}  -- Needed for the Target class type constraints
{-# Language FlexibleContexts #-}  -- Needed for the Target class type constraints

module Repositories (
    run,
    getDescription  -- Used by Index.hs::runIndex
) where

import Conduit (runConduit, (.|), sinkList)
import Control.Monad ((<=<))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT)
import Data.Either (fromRight)
import Data.Tagged
import Data.Text (pack, unpack, Text)
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Maybe (mapMaybe)
import Git
import Git.Libgit2 (lgFactory, LgRepo)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeFileName)
import System.IO.Error (tryIOError)
import Text.Ginger.GVal (GVal, toGVal, ToGVal)
import Text.Ginger.Html (Html)
import Text.Ginger.Run (Run)
import Text.Ginger.Parse (SourcePos)
import qualified Data.HashMap.Strict as HashMap

import Config
import Templates
import Types

{-
This is the entrypoint that receives the ``Config`` and uses it to map over our
repositories, reading from them and writing out their web pages using the given
templates.
-}
run :: Env -> IO ()
run env = do
    foldMap (processRepo env) . repoPaths . envConfig $ env  -- TODO: make concurrent
    return ()

{-
Pass the repository's folder, get its description. This is exported so that Index.hs can
use it too.
-}
getDescription :: FilePath -> IO Text
getDescription = fmap (fromRight "") . tryIOError . fmap pack . readFile . (</> "description")

----------------------------------------------------------------------------------------
-- Private -----------------------------------------------------------------------------

{-
This receives a file path to a single repository and tries to process it. If the
repository doesn't exist or is unreadable in any way we can forget about it and move on
(after informing the user of course).
-}
processRepo :: Env -> FilePath -> IO ()
processRepo env path = withRepository lgFactory path $ processRepo' env path

processRepo' :: Env -> FilePath -> ReaderT LgRepo IO ()
processRepo' env path = do
    let name = takeFileName path
    let output = outputDirectory (envConfig env) </> name
    liftIO $ createDirectoryIfMissing True output
    resolveReference "HEAD" >>= \case
        Nothing -> liftIO . print $ "gitserve: " <> name <> ": Failed to resolve HEAD."
        Just commitID -> do
            let gitHead = Tagged commitID
            -- Variables available in the ginger templates: --

            -- description: The description of the repository from repo/description, if
            -- it exists.
            description <- liftIO . getDescription $ path

            -- commits: A list of `Git.Commit` objects to HEAD.
            commits <- getCommits gitHead

            -- tree: A list of `TreeFile` objects at HEAD.
            tree <- getTree gitHead

            -- Run the generator --
            let scope = package env name description commits tree
            liftIO . mapM (generate output scope) $ envTemplates env
            liftIO . mapM (genTarget output scope $ envCommitTemplate env) $ commits
            liftIO . mapM (genTarget output scope $ envFileTemplate env) $ tree
            return ()

{-
The role of the function above is to gather information about a git repository and
package it all together in such a way that various parts can be accessed and used by
Ginger templates. `package` takes these pieces of information and places it all into a
hashmap which Ginger can use to look up variables.
-}
package
    :: Env
    -> FilePath
    -> Text
    -> [Commit LgRepo]
    -> [TreeFile]
    -> HashMap.HashMap Text (GVal (Run SourcePos IO Html))
package env name description commits tree = HashMap.fromList
    [ ("host", toGVal . host . envConfig $ env)
    , ("name", toGVal . pack $ name)
    , ("description", toGVal description)
    , ("commits", toGVal . reverse $ commits)  -- Could be optimised
    , ("tree", toGVal tree)
    ]

getCommits :: CommitOid LgRepo -> ReaderT LgRepo IO [Commit LgRepo]
getCommits commitID =
    sequence . mapMaybe loadCommit <=<
    runConduit $ sourceObjects Nothing commitID False .| sinkList

loadCommit :: ObjectOid LgRepo -> Maybe (ReaderT LgRepo IO (Commit LgRepo))
loadCommit (CommitObjOid oid) = Just $ lookupCommit oid
loadCommit _ = Nothing

getTree :: CommitOid LgRepo -> ReaderT LgRepo IO [TreeFile]
getTree commitID = do
    entries <- listTreeEntries =<< lookupTree . commitTree =<< lookupCommit commitID
    contents <- mapM (gvalTreeEntry . snd) entries
    return $ zipWith TreeFile (fmap fst entries) contents

gvalTreeEntry :: TreeEntry LgRepo -> ReaderT LgRepo IO TreeFileContents
gvalTreeEntry (BlobEntry oid kind) =
    FileContents . (,) (blobkindToMode kind) . decodeUtf8With lenientDecode <$> catBlob oid
gvalTreeEntry (TreeEntry oid) = FolderContents . fmap fst <$> (listTreeEntries =<< lookupTree oid)
gvalTreeEntry (CommitEntry _) = return . FileContents $ (ModeSubmodule, "No contents")  -- TODO

----------------------------------------------------------------------------------------
-- Targets -----------------------------------------------------------------------------

{-
A Target refers to a template scope and repository object whose information is available
in that scope. For example, commits are a target as they each generate a scope
containing that commit's information, and these scopes are each rendered in the
commitTemplate. The Target class generalises how each target is represented so that
genTarget can work on any target type.
-}
class ToGVal (Run SourcePos IO Html) a => Target a where
    identify :: a -> FilePath
    category :: a -> FilePath

instance Target (Commit LgRepo) where
    identify = (++ ".html") . show . untag . commitOid
    category = const "commit"

instance Target TreeFile where
    identify = unpack . treePathToHref . treeFilePath
    category = const "file"

genTarget
    :: Target a
    => FilePath
    -> HashMap.HashMap Text (GVal (Run SourcePos IO Html))
    -> Maybe Template
    -> a
    -> IO ()
genTarget _ _ Nothing _ = return ()
genTarget output scope (Just template) target = do
    let template' = template { templatePath = identify target }
    let scope' = scope <> HashMap.fromList [(pack . category $ target, toGVal target)]
    liftIO $ createDirectoryIfMissing True (output </> category target)
    generate (output </> category target) scope' template'
    return ()
