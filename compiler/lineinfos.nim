#
#
#           The Nim Compiler
#        (c) Copyright 2018 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module contains the ``TMsgKind`` enum as well as the
## ``TLineInfo`` object.

import ropes, tables, pathutils, hashes

from ast_types import
  PSym,     # Contextual details of the instantnation stack optionally refer to
            # the used symbol
  TLineInfo,
  FileIndex # Forward-declared to avoid cyclic dependencies

export FileIndex, TLineInfo

import reports

const
  explanationsBaseUrl* = "https://nim-lang.github.io/Nim"
    # was: "https://nim-lang.org/docs" but we're now usually showing devel docs
    # instead of latest release docs.

proc createDocLink*(urlSuffix: string): string =
  # os.`/` is not appropriate for urls.
  result = explanationsBaseUrl
  if urlSuffix.len > 0 and urlSuffix[0] == '/':
    result.add urlSuffix
  else:
    result.add "/" & urlSuffix

proc computeNotesVerbosity(): tuple[
    main: array[0..3, ReportKinds],
    foreign: ReportKinds,
    base: ReportKinds
  ] =
  ## Create configuration sets for the default compilation report verbosity

  result.base = (repErrorKinds + repInternalKinds)
  # Mandatory reports - cannot be turned off, present in all verbosity
  # settings

  when defined(debugOptions):
    # debug report for transition of the configuration options
    result.base.incl {rdbgOptionsPush, rdbgOptionsPop}

  result.main[3] = result.base + repWarningKinds + repHintKinds - {
    rsemObservableStores, rsemResultUsed, rsemAnyEnumConvert}

  result.main[2] = result.main[3] - {
    rsemVmStackTrace, rsemUninit, rsemExtendedContext, rsemProcessingStmt}

  result.main[1] = result.main[2] - {
    rsemProveField,
    rsemErrGcUnsafe,
    rextPath,
    rsemHintLibDependency,
    rsemGlobalVar,
    rintGCStats
  }

  result.main[0] = result.main[1] - {
    rintSuccessX,
    rextConf,
    rsemProcessing,
    rsemPattern,
    rcmdExecuting,
    rbackLinking
  }

  result.foreign = result.base + {
    rsemProcessing,
    rsemUserHint,
    rsemUserWarning,
    rsemUserHint,
    rsemUserWarning,
    rsemUserError,
    rintQuitCalled
  }

const
  NotesVerbosity* = computeNotesVerbosity()
  errXMustBeCompileTime* = "'$1' can only be used in compile-time context"
  errArgsNeedRunOption* = "arguments can only be given if the '--run' option is selected"


type
  TFileInfo* = object
    fullPath*: AbsoluteFile    ## This is a canonical full filesystem path
    projPath*: RelativeFile    ## This is relative to the project's root
    shortName*: string         ## short name of the module
    quotedName*: Rope          ## cached quoted short name for codegen
                               ## purposes
    quotedFullName*: Rope      ## cached quoted full name for codegen
                               ## purposes

    lines*: seq[string]        ## the source code of the module used for
                               ## better error messages and embedding the
                               ## original source in the generated code

    dirtyFile*: AbsoluteFile   ## the file that is actually read into memory
                               ## and parsed; usually "" but is used
                               ## for 'nimsuggest'
    hash*: string              ## the checksum of the file
    dirty*: bool               ## for 'nimfix' / 'nimpretty' like tooling
    when defined(nimpretty):
      fullContent*: string

  TErrorOutput* = enum
    eStdOut
    eStdErr

  TErrorOutputs* = set[TErrorOutput]

  ERecoverableError* = object of ValueError
  ESuggestDone* = object of ValueError

proc `==`*(a, b: FileIndex): bool {.borrow.}

proc hash*(i: TLineInfo): Hash =
  hash (i.line.int, i.col.int, i.fileIndex.int)

proc raiseRecoverableError*(msg: string) {.noinline.} =
  raise newException(ERecoverableError, msg)

const
  InvalidFileIdx* = FileIndex(-1)
  unknownLineInfo* = TLineInfo(line: 0, col: -1, fileIndex: InvalidFileIdx)

type
  Severity* {.pure.} = enum ## VS Code only supports these three
    Hint, Warning, Error

const
  trackPosInvalidFileIdx* = FileIndex(-2) ## special marker so that no
  ## suggestions are produced within comments and string literals
  commandLineIdx* = FileIndex(-3)

type
  MsgConfig* = object ## does not need to be stored in the incremental cache
    trackPos*: TLineInfo
    trackPosAttached*: bool ## whether the tracking position was attached to
                            ## some close token.

    errorOutputs*: TErrorOutputs
    msgContext*: seq[tuple[info: TLineInfo, detail: PSym]] ## \ Contextual
    ## information about instantiation stack - "template/generic
    ## instantiation of" message is constructed from this field. Right now
    ## `.detail` field is only used in the `sem.semMacroExpr()`,
    ## `seminst.generateInstance()` and `semexprs.semTemplateExpr()`. In
    ## all other cases this field is left empty (SemReport is `skUnknown`)
    reports*: ReportList ## Intermediate storage for the
    lastError*: TLineInfo
    filenameToIndexTbl*: Table[string, FileIndex]
    fileInfos*: seq[TFileInfo] ## Information about all known source files
    ## is stored in this field - full/relative paths, list of line etc.
    ## (For full list see `TFileInfo`)
    systemFileIdx*: FileIndex

proc initMsgConfig*(): MsgConfig =
  result.msgContext = @[]
  result.lastError = unknownLineInfo
  result.filenameToIndexTbl = initTable[string, FileIndex]()
  result.fileInfos = @[]
  result.errorOutputs = {eStdOut, eStdErr}
  result.filenameToIndexTbl["???"] = FileIndex(-1)
