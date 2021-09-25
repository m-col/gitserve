{-# Language LambdaCase #-}
{-# Language OverloadedStrings #-}  -- Needed for resolveReference
{-# Language FlexibleInstances #-}  -- Needed for `instance ToGVal`
{-# Language MultiParamTypeClasses #-}  -- Needed for `instance ToGVal`
{-# Language InstanceSigs #-}  -- Needed for toGVal type signature

module Repositories (
    run
) where

import Conduit (runConduit, (.|), sinkList)
import Control.Monad ((<=<))
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Reader (ReaderT)
import Data.Default (def)
import Data.Either (fromRight)
import Data.Tagged
import Data.Text (pack, Text, strip, breakOn)
import Data.Maybe (mapMaybe)
import Git
import Git.Libgit2 (lgFactory, LgRepo)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>), takeFileName)
import System.IO.Error (tryIOError)
import Text.Ginger.GVal (GVal, toGVal, ToGVal, asText, asHtml, asLookup)
import Text.Ginger.Html (Html, html)
import Text.Ginger.Run (Run)
import Text.Ginger.Parse (SourcePos)
import qualified Data.HashMap.Strict as HashMap

import Config (Config, repoPaths, outputDirectory, host)
import Templates (Template, generate, templatePath)

{-
This is the entrypoint that receives the ``Config`` and uses it to map over our
repositories, reading from them and writing out their web pages using the given
templates.
-}
run :: Config -> [Template] -> Maybe Template -> IO ()
run config templates index = do
    foldMap (processRepo templates config) . repoPaths $ config
    runIndex config index

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
    let name = takeFileName path
    let output = outputDirectory config </> name
    liftIO $ createDirectoryIfMissing True output
    resolveReference "HEAD" >>= \case
        Nothing -> liftIO . print $ "gitserve: " <> name <> ": Failed to resolve HEAD."
        Just commitID -> do
            let gitHead = Tagged commitID
            -- Variables available in the ginger templates: --

            -- description: The description of the repository from repo/description, if
            -- it exists.
            description <- liftIO $ getDescription $ path </> "description"

            -- commits: A list of `Git.Commit` objects to HEAD.
            commits <- getCommits gitHead

            -- tree: A list of `(TreeFilePath, TreeEntry r)` objects at HEAD.
            tree <- getTree gitHead

            -- Run the generator --
            let repo = package config name description commits tree
            liftIO . mapM (generate output repo) $ templates
            return ()

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
    -> [TreeFile]
    -> HashMap.HashMap Text (GVal (Run SourcePos IO Html))
package config name description commits tree = HashMap.fromList
    [ ("host", toGVal $ host config)
    , ("name", toGVal $ pack name)
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

data TreeFile = TreeFile
    { treeFilePath :: TreeFilePath
    , treeEntry :: TreeEntry LgRepo
    }

getTree :: CommitOid LgRepo -> ReaderT LgRepo IO [TreeFile]
getTree commitID = do
    entries <- listTreeEntries =<< lookupTree . commitTree =<< lookupCommit commitID
    return $ uncurry TreeFile <$> entries

getDescription :: FilePath -> IO Text
getDescription path = fromRight "" <$> tryIOError (pack <$> readFile path)

{-
Here we define how commits can be accessed and represented in Ginger templates.
-}
instance ToGVal m (Commit LgRepo) where
    toGVal :: Commit LgRepo -> GVal m
    toGVal commit = def
        { asHtml = html . pack . show . commitLog $ commit
        , asText = pack . show . commitLog $ commit
        , asLookup = Just . commitAsLookup $ commit
        }

commitAsLookup :: Commit LgRepo -> Text -> Maybe (GVal m)
commitAsLookup commit = \case
    "title" -> Just . toGVal . strip . fst . breakOn "\n" . commitLog $ commit
    "body" -> Just . toGVal . strip . snd . breakOn "\n" . commitLog $ commit
    "message" -> Just . toGVal . strip . commitLog $ commit
    "author" -> Just . toGVal . strip . signatureName . commitAuthor $ commit
    "committer" -> Just . toGVal . strip . signatureName . commitCommitter $ commit
    "author_email" -> Just . toGVal . strip . signatureEmail . commitAuthor $ commit
    "committer_email" -> Just . toGVal . strip . signatureEmail . commitCommitter $ commit
    "authored" -> Just . toGVal . show . signatureWhen . commitAuthor $ commit
    "committed" -> Just . toGVal . show . signatureWhen . commitCommitter $ commit
    "encoding" -> Just . toGVal . strip . commitEncoding $ commit
    _ -> Nothing


{-
Here we define how files in the tree can be accessed by Ginger templates.
-}
instance ToGVal m TreeFile where
    toGVal :: TreeFile -> GVal m
    toGVal treefile = def
        { asHtml = html . pack . show . treeFilePath $ treefile
        , asText = pack . show . treeFilePath $ treefile
        , asLookup = Just . treeAsLookup $ treefile
        }

treeAsLookup :: TreeFile -> Text -> Maybe (GVal m)
treeAsLookup treefile = \case
    "path" -> Just . toGVal . treeFilePath $ treefile
    _ -> Nothing

----------------------------------------------------------------------------------------

{-
This creates the main index file from the index template, using information from all
configured respositories.
-}
runIndex :: Config -> Maybe Template -> IO ()
runIndex _ Nothing = return ()
runIndex config (Just template) = do
    let paths = repoPaths config
    descriptions <- sequence . fmap (getDescription . flip (</>) "description") $ paths
    let repos = zipWith ($) (Repo <$> takeFileName <$> paths) descriptions
    let indexScope = packageIndex config repos
    generate (outputDirectory config) indexScope (template { templatePath = "index.html" })
    return ()

packageIndex
    :: Config
    -> [Repo]
    -> HashMap.HashMap Text (GVal (Run SourcePos IO Html))
packageIndex config repos = HashMap.fromList
    [ ("host", toGVal $ host config)
    , ("repositories", toGVal repos)
    ]

{-
The index template can access variables in the index scope. The primary variable here is
the list of repositories, which can be looped over and each repo entry has some
properties that can be accessed. These are defined here.
-}
data Repo = Repo
    { repoName :: FilePath
    , repoDescription :: Text
    }

instance ToGVal m Repo where
    toGVal :: Repo -> GVal m
    toGVal repo = def
        { asHtml = html . pack . show . repoName $ repo
        , asText = pack . show . repoName $ repo
        , asLookup = Just . repoAsLookup $ repo
        }

repoAsLookup :: Repo -> Text -> Maybe (GVal m)
repoAsLookup repo = \case
    "name" -> Just . toGVal . repoName $ repo
    "description" -> Just . toGVal . repoDescription $ repo
    _ -> Nothing
