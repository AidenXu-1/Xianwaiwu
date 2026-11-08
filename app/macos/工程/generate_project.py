#!/usr/bin/env python3
"""Deterministically regenerate the native project without an external generator."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
out=root/'弦外屋.xcodeproj';out.mkdir(exist_ok=True)
def uid(s):return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def obj(k,body):return f'{uid(k)} = {{ {body} }};'
files=sorted((root/'源码').glob('*.swift'))
objects=[]; refs=[]; builds=[]
for f in files:
 r=uid('ref'+f.name);b=uid('build'+f.name);refs.append(r);builds.append(b)
 objects += [obj('ref'+f.name,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{f.name}"; sourceTree = "<group>";'),obj('build'+f.name,f'isa = PBXBuildFile; fileRef = {r};')]
objects += [
 obj('project',f'isa = PBXProject; buildConfigurationList = {uid("projectConfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; knownRegions = ("zh-Hans", en, Base); mainGroup = {uid("main")}; productRefGroup = {uid("products")}; projectDirPath = ""; targets = ({uid("target")});'),
 obj('main',f'isa = PBXGroup; children = ({uid("sources")}, {uid("products")}); sourceTree = "<group>";'),
 obj('sources',f'isa = PBXGroup; path = "源码"; children = ({",".join(refs)}); sourceTree = "<group>";'),
 obj('products',f'isa = PBXGroup; name = Products; children = ({uid("app")}); sourceTree = "<group>";'),
 obj('app','isa = PBXFileReference; explicitFileType = wrapper.application; path = "弦外屋.app"; sourceTree = BUILT_PRODUCTS_DIR;'),
 obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {uid("targetConfigs")}; buildPhases = ({uid("swift")}, {uid("frameworks")}, {uid("resources")}, {uid("icon")}); buildRules = (); dependencies = (); name = Xianwaiwu; productName = "弦外屋"; productReference = {uid("app")}; productType = "com.apple.product-type.application";'),
 obj('swift',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)}); runOnlyForDeploymentPostprocessing = 0;'),
 obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;'),
 obj('resources','isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;'),
 obj('icon','isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/bash; shellScript = "bash \\"$SRCROOT/工程/prepare-icon.sh\\""; alwaysOutOfDate = 1; name = "木吉他图标";'.replace('\\"','\\"')),
]
# Shell script is an OpenStep quoted string.
objects[-1]=obj('icon','isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/bash; shellScript = "bash \\"$SRCROOT/工程/prepare-icon.sh\\""; alwaysOutOfDate = 1; name = "木吉他图标";')
for level in ['project','target']:
 configs=[]
 for config in ['Debug','Release']:
  key=level+config;configs.append(uid(key))
  settings = 'CLANG_ENABLE_MODULES = YES; MACOSX_DEPLOYMENT_TARGET = 14.0; SDKROOT = macosx; ARCHS = arm64; ONLY_ACTIVE_ARCH = YES;'
  if level=='target': settings += ' PRODUCT_NAME = "弦外屋"; EXECUTABLE_NAME = Xianwaiwu; PRODUCT_BUNDLE_IDENTIFIER = local.aiden.xianwaiwu; INFOPLIST_FILE = "工程/Info.plist"; GENERATE_INFOPLIST_FILE = NO; SWIFT_VERSION = 5.0; SWIFT_OPTIMIZATION_LEVEL = "-O"; CODE_SIGNING_ALLOWED = NO; ENABLE_APP_SANDBOX = NO; ENABLE_USER_SCRIPT_SANDBOXING = NO; COMBINE_HIDPI_IMAGES = YES;'
  objects.append(obj(key,f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{ {settings} }};'))
 objects.append(obj(level+'Configs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;'))
(out/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+'\n}; rootObject = '+uid('project')+'; }\n')
scheme=out/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
(scheme/'Xianwaiwu.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2720" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="弦外屋.app" BlueprintName="Xianwaiwu" ReferencedContainer="container:弦外屋.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid('target')}" BuildableName="弦外屋.app" BlueprintName="Xianwaiwu" ReferencedContainer="container:弦外屋.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>''')
print(out)
