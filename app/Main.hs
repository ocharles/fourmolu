{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Exception (throwIO)
import Control.Monad
import Data.Bool (bool)
import Data.Functor.Identity (Identity (..))
import Data.List (intercalate, sort)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Version (showVersion)
import qualified Data.Yaml as Yaml
import Development.GitRev
import Options.Applicative
import Ormolu
import Ormolu.Config
import Ormolu.Diff.Text (diffText, printTextDiff)
import Ormolu.Fixity (FixityInfo)
import Ormolu.Parser (manualExts)
import Ormolu.Terminal
import Ormolu.Utils (showOutputable)
import Ormolu.Utils.Cabal
import Ormolu.Utils.Fixity
  ( getFixityOverridesForSourceFile,
    parseFixityDeclarationStr,
  )
import Ormolu.Utils.IO
import Paths_fourmolu (version)
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)
import qualified System.FilePath as FP
import System.IO (hPutStrLn, stderr)

-- | Entry point of the program.
main :: IO ()
main = do
  opts@Opts {..} <- execParser optsParserInfo

  cfg <- case optInputFiles of
    [] -> mkConfigFromCWD opts
    ["-"] -> mkConfigFromCWD opts
    file : _ -> mkConfig file opts
  let formatOne' =
        formatOne
          optCabal
          optMode
          optSourceType
          cfg

  exitCode <- case optInputFiles of
    [] -> formatOne' Nothing
    ["-"] -> formatOne' Nothing
    [x] -> formatOne' (Just x)
    xs -> do
      let selectFailure = \case
            ExitSuccess -> Nothing
            ExitFailure n -> Just n
      errorCodes <-
        mapMaybe selectFailure <$> mapM (formatOne' . Just) (sort xs)
      return $
        if null errorCodes
          then ExitSuccess
          else
            ExitFailure $
              if all (== 100) errorCodes
                then 100
                else 102
  exitWith exitCode

-- | Format a single input.
formatOne ::
  -- | How to use .cabal files
  CabalOpts ->
  -- | Mode of operation
  Mode ->
  -- | The 'SourceType' requested by the user
  Maybe SourceType ->
  -- | Configuration
  Config RegionIndices ->
  -- | File to format or stdin as 'Nothing'
  Maybe FilePath ->
  IO ExitCode
formatOne CabalOpts {..} mode reqSourceType rawConfig mpath =
  withPrettyOrmoluExceptions (cfgColorMode rawConfig) $ do
    case FP.normalise <$> mpath of
      -- input source = STDIN
      Nothing -> do
        resultConfig <-
          ( if optDoNotUseCabal
              then pure defaultCabalInfo
              else case optStdinInputFile of
                Just stdinInputFile ->
                  getCabalInfoForSourceFile stdinInputFile
                Nothing -> throwIO OrmoluMissingStdinInputFile
            )
            >>= patchConfig Nothing
        case mode of
          Stdout -> do
            ormoluStdin resultConfig >>= TIO.putStr
            return ExitSuccess
          InPlace -> do
            hPutStrLn
              stderr
              "In place editing is not supported when input comes from stdin."
            -- 101 is different from all the other exit codes we already use.
            return (ExitFailure 101)
          Check -> do
            -- ormoluStdin is not used because we need the originalInput
            originalInput <- getContentsUtf8
            let stdinRepr = "<stdin>"
            formattedInput <-
              ormolu resultConfig stdinRepr (T.unpack originalInput)
            handleDiff originalInput formattedInput stdinRepr
      -- input source = a file
      Just inputFile -> do
        resultConfig <-
          ( if optDoNotUseCabal
              then pure defaultCabalInfo
              else getCabalInfoForSourceFile inputFile
            )
            >>= patchConfig (Just (detectSourceType inputFile))
        case mode of
          Stdout -> do
            ormoluFile resultConfig inputFile >>= TIO.putStr
            return ExitSuccess
          InPlace -> do
            -- ormoluFile is not used because we need originalInput
            originalInput <- readFileUtf8 inputFile
            formattedInput <-
              ormolu resultConfig inputFile (T.unpack originalInput)
            when (formattedInput /= originalInput) $
              writeFileUtf8 inputFile formattedInput
            return ExitSuccess
          Check -> do
            -- ormoluFile is not used because we need originalInput
            originalInput <- readFileUtf8 inputFile
            formattedInput <-
              ormolu resultConfig inputFile (T.unpack originalInput)
            handleDiff originalInput formattedInput inputFile
  where
    patchConfig mdetectedSourceType cabalInfo@CabalInfo {..} = do
      let depsFromCabal =
            -- It makes sense to take into account the operator info for the
            -- package itself if we know it, as if it were its own
            -- dependency.
            case ciPackageName of
              Nothing -> ciDependencies
              Just p -> Set.insert p ciDependencies
      fixityOverrides <- getFixityOverridesForSourceFile cabalInfo
      return
        rawConfig
          { cfgDynOptions = cfgDynOptions rawConfig ++ ciDynOpts,
            cfgFixityOverrides =
              Map.unionWith (<>) (cfgFixityOverrides rawConfig) fixityOverrides,
            cfgDependencies =
              Set.union (cfgDependencies rawConfig) depsFromCabal,
            cfgSourceType =
              fromMaybe
                ModuleSource
                (reqSourceType <|> mdetectedSourceType)
          }
    handleDiff originalInput formattedInput fileRepr =
      case diffText originalInput formattedInput fileRepr of
        Nothing -> return ExitSuccess
        Just diff -> do
          runTerm (printTextDiff diff) (cfgColorMode rawConfig) stderr
          -- 100 is different to all the other exit code that are emitted
          -- either from an 'OrmoluException' or from 'error' and
          -- 'notImplemented'.
          return (ExitFailure 100)

----------------------------------------------------------------------------
-- Command line options parsing

-- | All command line options.
data Opts = Opts
  { -- | Mode of operation
    optMode :: !Mode,
    -- | Whether to make the output quieter
    optQuiet :: !Bool,
    -- | Ormolu 'Config'
    optConfig :: !(Config RegionIndices),
    -- | Options related to info extracted from .cabal files
    optCabal :: CabalOpts,
    -- | Source type option, where 'Nothing' means autodetection
    optSourceType :: !(Maybe SourceType),
    -- | Fourmolu-specific options
    optPrinterOpts :: !PrinterOptsPartial,
    -- | Haskell source files to format or stdin (when the list is empty)
    optInputFiles :: ![FilePath]
  }

-- | Mode of operation.
data Mode
  = -- | Output formatted source code to stdout
    Stdout
  | -- | Overwrite original file
    InPlace
  | -- | Exit with non-zero status code if
    -- source is not already formatted
    Check
  deriving (Eq, Show, Bounded, Enum)

-- | Configuration related to .cabal files.
data CabalOpts = CabalOpts
  { -- | DO NOT extract default-extensions and dependencies from .cabal files
    optDoNotUseCabal :: Bool,
    -- | Optional path to a file which will be used to find a .cabal file
    -- when using input from stdin
    optStdinInputFile :: Maybe FilePath
  }
  deriving (Show)

optsParserInfo :: ParserInfo Opts
optsParserInfo =
  info (helper <*> ver <*> exts <*> optsParser) . mconcat $
    [fullDesc]
  where
    ver :: Parser (a -> a)
    ver =
      infoOption verStr . mconcat $
        [ long "version",
          short 'v',
          help "Print version of the program"
        ]
    verStr =
      intercalate
        "\n"
        [ unwords
            [ "fourmolu",
              showVersion version,
              $gitBranch,
              $gitHash
            ],
          "using ghc-lib-parser " ++ VERSION_ghc_lib_parser
        ]
    exts :: Parser (a -> a)
    exts =
      infoOption displayExts . mconcat $
        [ long "manual-exts",
          help "Display extensions that need to be enabled manually"
        ]
    displayExts = unlines $ sort (showOutputable <$> manualExts)

optsParser :: Parser Opts
optsParser =
  Opts
    <$> ( (fmap (bool Stdout InPlace) . switch . mconcat)
            [ short 'i',
              help "A shortcut for --mode inplace"
            ]
            <|> (option parseBoundedEnum . mconcat)
              [ long "mode",
                short 'm',
                metavar "MODE",
                value Stdout,
                help "Mode of operation: 'stdout' (the default), 'inplace', or 'check'"
              ]
        )
    <*> (switch . mconcat)
      [ long "quiet",
        short 'q',
        help "Make output quieter"
      ]
    <*> configParser
    <*> cabalOptsParser
    <*> sourceTypeParser
    <*> printerOptsParser
    <*> (many . strArgument . mconcat)
      [ metavar "FILE",
        help "Haskell source files to format or stdin (the default)"
      ]

cabalOptsParser :: Parser CabalOpts
cabalOptsParser =
  CabalOpts
    <$> (switch . mconcat)
      [ long "no-cabal",
        help "Do not extract default-extensions and dependencies from .cabal files"
      ]
    <*> (optional . strOption . mconcat)
      [ long "stdin-input-file",
        help "Path which will be used to find the .cabal file when using input from stdin"
      ]

configParser :: Parser (Config RegionIndices)
configParser =
  Config
    <$> (fmap (fmap DynOption) . many . strOption . mconcat)
      [ long "ghc-opt",
        short 'o',
        metavar "OPT",
        help "GHC options to enable (e.g. language extensions)"
      ]
    <*> ( fmap (Map.fromListWith (<>) . mconcat)
            . many
            . option parseFixityDeclaration
            . mconcat
        )
      [ long "fixity",
        short 'f',
        metavar "FIXITY",
        help "Fixity declaration to use (an override)"
      ]
    <*> (fmap Set.fromList . many . strOption . mconcat)
      [ long "package",
        short 'p',
        metavar "PACKAGE",
        help "Explicitly specified dependency (for operator fixity/precedence only)"
      ]
    <*> (switch . mconcat)
      [ long "unsafe",
        short 'u',
        help "Do formatting faster but without automatic detection of defects"
      ]
    <*> (switch . mconcat)
      [ long "debug",
        short 'd',
        help "Output information useful for debugging"
      ]
    <*> (switch . mconcat)
      [ long "check-idempotence",
        short 'c',
        help "Fail if formatting is not idempotent"
      ]
    -- We cannot parse the source type here, because we might need to do
    -- autodection based on the input file extension (not available here)
    -- before storing the resolved value in the config struct.
    <*> pure ModuleSource
    <*> (option parseBoundedEnum . mconcat)
      [ long "color",
        metavar "WHEN",
        value Auto,
        help "Colorize the output; WHEN can be 'never', 'always', or 'auto' (the default)"
      ]
    <*> ( RegionIndices
            <$> (optional . option auto . mconcat)
              [ long "start-line",
                metavar "START",
                help "Start line of the region to format (starts from 1)"
              ]
            <*> (optional . option auto . mconcat)
              [ long "end-line",
                metavar "END",
                help "End line of the region to format (inclusive)"
              ]
        )
    <*> pure defaultPrinterOpts

printerOptsParser :: Parser PrinterOptsPartial
printerOptsParser = do
  poIndentation <-
    (optional . option auto . mconcat)
      [ long "indentation",
        metavar "WIDTH",
        help $
          "Number of spaces per indentation step"
            <> showDefaultValue poIndentation
      ]
  poCommaStyle <-
    (optional . option parseBoundedEnum . mconcat)
      [ long "comma-style",
        metavar "STYLE",
        help $
          "How to place commas in multi-line lists, records etc: "
            <> showAllValues @CommaStyle
            <> showDefaultValue poCommaStyle
      ]
  poImportExportCommaStyle <-
    (optional . option parseBoundedEnum . mconcat)
      [ long "import-export-comma-style",
        metavar "IESTYLE",
        help $
          "How to place commas in multi-line import and export lists: "
            <> showAllValues @CommaStyle
            <> showDefaultValue poImportExportCommaStyle
      ]
  poIndentWheres <-
    (optional . option parseBoundedEnum . mconcat)
      [ long "indent-wheres",
        metavar "BOOL",
        help $
          "Whether to indent 'where' bindings past the preceding body"
            <> " (rather than half-indenting the 'where' keyword)"
            <> showDefaultValue poIndentWheres
      ]
  poRecordBraceSpace <-
    (optional . option parseBoundedEnum . mconcat)
      [ long "record-brace-space",
        metavar "BOOL",
        help $
          "Whether to leave a space before an opening record brace"
            <> showDefaultValue poRecordBraceSpace
      ]
  poDiffFriendlyImportExport <-
    (optional . option parseBoundedEnum . mconcat)
      [ long "diff-friendly-import-export",
        metavar "BOOL",
        help $
          "Whether to make use of extra commas in import/export lists"
            <> " (as opposed to Ormolu's style)"
            <> showDefaultValue poDiffFriendlyImportExport
      ]
  poRespectful <-
    (optional . option parseBoundedEnum . mconcat)
      [ long "respectful",
        metavar "BOOL",
        help $
          "Give the programmer more choice on where to insert blank lines"
            <> showDefaultValue poRespectful
      ]
  poHaddockStyle <-
    (optional . option parseBoundedEnum . mconcat)
      [ long "haddock-style",
        metavar "STYLE",
        help $
          "How to print Haddock comments: "
            <> showAllValues @HaddockPrintStyle
            <> showDefaultValue poHaddockStyle
      ]
  poNewlinesBetweenDecls <-
    (optional . option auto . mconcat)
      [ long "newlines-between-decls",
        metavar "HEIGHT",
        help $
          "Number of spaces between top-level declarations"
            <> showDefaultValue poNewlinesBetweenDecls
      ]
  pure PrinterOpts {..}

sourceTypeParser :: Parser (Maybe SourceType)
sourceTypeParser =
  (option parseSourceType . mconcat)
    [ long "source-type",
      short 't',
      metavar "TYPE",
      value Nothing,
      help "Set the type of source; TYPE can be 'module', 'sig', or 'auto' (the default)"
    ]

----------------------------------------------------------------------------
-- Helpers

-- | A standard parser of CLI option arguments, applicable to arguments that
-- have a finite (preferably small) number of possible values. (Basically an
-- inverse of 'toCLIArgument'.)
parseBoundedEnum ::
  forall a.
  (Enum a, Bounded a, ToCLIArgument a) =>
  ReadM a
parseBoundedEnum =
  eitherReader
    ( \s ->
        case lookup s argumentToValue of
          Just v -> Right v
          Nothing ->
            Left $
              "unknown value: '"
                <> s
                <> "'\nValid values are: "
                <> showAllValues @a
                <> "."
    )
  where
    argumentToValue = map (\x -> (toCLIArgument x, x)) [minBound ..]

-- | Values that appear as arguments of CLI options and thus have
-- a corresponding textual representation.
class ToCLIArgument a where
  -- | Convert a value to its representation as a CLI option argument.
  toCLIArgument :: a -> String

  -- | Convert a value to its representation as a CLI option argument wrapped
  -- in apostrophes.
  toCLIArgument' :: a -> String
  toCLIArgument' x = "'" <> toCLIArgument x <> "'"

instance ToCLIArgument Bool where
  toCLIArgument True = "true"
  toCLIArgument False = "false"

instance ToCLIArgument CommaStyle where
  toCLIArgument Leading = "leading"
  toCLIArgument Trailing = "trailing"

instance ToCLIArgument Int where
  toCLIArgument = show

instance ToCLIArgument HaddockPrintStyle where
  toCLIArgument HaddockSingleLine = "single-line"
  toCLIArgument HaddockMultiLine = "multi-line"

instance ToCLIArgument Mode where
  toCLIArgument Stdout = "stdout"
  toCLIArgument InPlace = "inplace"
  toCLIArgument Check = "check"

instance ToCLIArgument ColorMode where
  toCLIArgument Never = "never"
  toCLIArgument Always = "always"
  toCLIArgument Auto = "auto"

showAllValues :: forall a. (Enum a, Bounded a, ToCLIArgument a) => String
showAllValues = format (map toCLIArgument' [(minBound :: a) ..])
  where
    format [] = []
    format [x] = x
    format [x1, x2] = x1 <> " or " <> x2
    format (x : xs) = x <> ", " <> format xs

-- | CLI representation of the default value of an option, formatted for
-- inclusion in the help text.
showDefaultValue ::
  ToCLIArgument a =>
  (PrinterOptsTotal -> Identity a) ->
  String
showDefaultValue =
  (" (default " <>)
    . (<> ")")
    . toCLIArgument'
    . runIdentity
    . ($ defaultPrinterOpts)

-- | Build the full config, by adding 'PrinterOpts' from a file, if found.
mkConfig :: FilePath -> Opts -> IO (Config RegionIndices)
mkConfig path Opts {..} = do
  mFourmoluConfig <-
    loadConfigFile path >>= \case
      ConfigLoaded f cfg -> do
        unless optQuiet $
          hPutStrLn stderr $
            "Loaded config from: " <> f
        printDebug $ show cfg
        return $ Just cfg
      ConfigParseError f e -> do
        hPutStrLn stderr $
          unlines
            [ "Failed to load " <> f <> ":",
              Yaml.prettyPrintParseException e
            ]
        exitWith $ ExitFailure 400
      ConfigNotFound searchDirs -> do
        printDebug
          . unlines
          $ ("No " ++ show configFileName ++ " found in any of:")
            : map ("  " ++) searchDirs
        return Nothing
  return $
    optConfig
      { cfgPrinterOpts =
          fillMissingPrinterOpts
            (optPrinterOpts <> maybe mempty cfgFilePrinterOpts mFourmoluConfig)
            (cfgPrinterOpts optConfig),
        cfgFixityOverrides =
          -- cfgFileFixities should go on the right so that command line
          -- fixity overrides takes precedence.
          cfgFixityOverrides optConfig <> maybe mempty cfgFileFixities mFourmoluConfig
      }
  where
    printDebug = when (cfgDebug optConfig) . hPutStrLn stderr

mkConfigFromCWD :: Opts -> IO (Config RegionIndices)
mkConfigFromCWD opts = do
  cwd <- getCurrentDirectory
  mkConfig cwd opts

-- | Parse a fixity declaration.
parseFixityDeclaration :: ReadM [(String, FixityInfo)]
parseFixityDeclaration = eitherReader parseFixityDeclarationStr

-- | Parse the 'SourceType'. 'Nothing' means that autodetection based on
-- file extension is requested.
parseSourceType :: ReadM (Maybe SourceType)
parseSourceType = eitherReader $ \case
  "module" -> Right (Just ModuleSource)
  "sig" -> Right (Just SignatureSource)
  "auto" -> Right Nothing
  s -> Left $ "unknown source type: " ++ s
