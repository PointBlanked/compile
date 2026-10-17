# Owner: Maxwell. Regenerates EchoGuideApp/EchoGuideApp.xcodeproj from the files
# in EchoGuideApp/Sources. Run from the repo root after adding or removing an
# app source file: python3 scripts/gen_xcodeproj.py
import hashlib, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'EchoGuideApp')
def oid(name): return hashlib.md5(name.encode()).hexdigest()[:24].upper()

srcs = sorted(f for f in os.listdir(os.path.join(ROOT, 'Sources')) if f.endswith('.swift'))
P=oid('project'); T=oid('target'); MAIN=oid('maingroup'); SRCG=oid('srcgroup'); RESG=oid('resgroup'); PRODG=oid('prodgroup')
APP=oid('app.product'); PKG=oid('localpkg'); DEP=oid('pkgdep'); DEPBF=oid('pkgdep.bf')
SP=oid('sources.phase'); FP=oid('frameworks.phase'); RP=oid('resources.phase')
PCL=oid('proj.cfglist'); TCL=oid('tgt.cfglist'); PD=oid('proj.debug'); PR=oid('proj.release'); TD=oid('tgt.debug'); TR=oid('tgt.release')
INFO=oid('info.plist')
res=[('Assets.xcassets','folder.assetcatalog','Assets.xcassets'),('echoguide.sample.json','text.json','Resources/echoguide.sample.json'),('Models','folder','Resources/Models')]
L=[]; a=L.append
a('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 60;\n\tobjects = {\n')
a('\n/* Begin PBXBuildFile section */\n')
for s in srcs: a(f'\t\t{oid("bf."+s)} /* {s} in Sources */ = {{isa = PBXBuildFile; fileRef = {oid("fr."+s)} /* {s} */; }};\n')
for n,_,_ in res: a(f'\t\t{oid("bf."+n)} /* {n} in Resources */ = {{isa = PBXBuildFile; fileRef = {oid("fr."+n)} /* {n} */; }};\n')
a(f'\t\t{DEPBF} /* EchoGuide in Frameworks */ = {{isa = PBXBuildFile; productRef = {DEP} /* EchoGuide */; }};\n')
a('/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */\n')
a(f'\t\t{APP} /* EchoGuideApp.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = EchoGuideApp.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
for s in srcs: a(f'\t\t{oid("fr."+s)} /* {s} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {s}; sourceTree = "<group>"; }};\n')
for n,t,p in res: a(f'\t\t{oid("fr."+n)} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = {t}; name = {n}; path = {p}; sourceTree = "<group>"; }};\n')
a(f'\t\t{INFO} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};\n')
a('/* End PBXFileReference section */\n\n/* Begin PBXFrameworksBuildPhase section */\n')
a(f'\t\t{FP} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{DEPBF} /* EchoGuide in Frameworks */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
a('/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXGroup section */\n')
a(f'\t\t{MAIN} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{SRCG} /* Sources */,\n\t\t\t\t{RESG} /* Resources */,\n\t\t\t\t{INFO} /* Info.plist */,\n\t\t\t\t{PRODG} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
a(f'\t\t{SRCG} /* Sources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'+''.join(f'\t\t\t\t{oid("fr."+s)} /* {s} */,\n' for s in srcs)+'\t\t\t);\n\t\t\tpath = Sources;\n\t\t\tsourceTree = "<group>";\n\t\t};\n')
a(f'\t\t{RESG} /* Resources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'+''.join(f'\t\t\t\t{oid("fr."+n)} /* {n} */,\n' for n,_,_ in res)+'\t\t\t);\n\t\t\tname = Resources;\n\t\t\tsourceTree = "<group>";\n\t\t};\n')
a(f'\t\t{PRODG} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{APP} /* EchoGuideApp.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
a('/* End PBXGroup section */\n\n/* Begin PBXNativeTarget section */\n')
a(f'\t\t{T} /* EchoGuideApp */ = {{\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {TCL} /* Build configuration list for PBXNativeTarget "EchoGuideApp" */;\n\t\t\tbuildPhases = (\n\t\t\t\t{SP} /* Sources */,\n\t\t\t\t{FP} /* Frameworks */,\n\t\t\t\t{RP} /* Resources */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = EchoGuideApp;\n\t\t\tpackageProductDependencies = (\n\t\t\t\t{DEP} /* EchoGuide */,\n\t\t\t);\n\t\t\tproductName = EchoGuideApp;\n\t\t\tproductReference = {APP} /* EchoGuideApp.app */;\n\t\t\tproductType = "com.apple.product-type.application";\n\t\t}};\n')
a('/* End PBXNativeTarget section */\n\n/* Begin PBXProject section */\n')
a(f'\t\t{P} /* Project object */ = {{\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 1600;\n\t\t\t\tLastUpgradeCheck = 1600;\n\t\t\t}};\n\t\t\tbuildConfigurationList = {PCL} /* Build configuration list for PBXProject "EchoGuideApp" */;\n\t\t\tcompatibilityVersion = "Xcode 15.0";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n\t\t\tmainGroup = {MAIN};\n\t\t\tpackageReferences = (\n\t\t\t\t{PKG} /* XCLocalSwiftPackageReference ".." */,\n\t\t\t);\n\t\t\tproductRefGroup = {PRODG} /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n\t\t\ttargets = (\n\t\t\t\t{T} /* EchoGuideApp */,\n\t\t\t);\n\t\t}};\n')
a('/* End PBXProject section */\n\n/* Begin PBXResourcesBuildPhase section */\n')
a(f'\t\t{RP} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n'+''.join(f'\t\t\t\t{oid("bf."+n)} /* {n} in Resources */,\n' for n,_,_ in res)+'\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n')
a('/* End PBXResourcesBuildPhase section */\n\n/* Begin PBXSourcesBuildPhase section */\n')
a(f'\t\t{SP} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n'+''.join(f'\t\t\t\t{oid("bf."+s)} /* {s} in Sources */,\n' for s in srcs)+'\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n')
a('/* End PBXSourcesBuildPhase section */\n\n/* Begin XCBuildConfiguration section */\n')
def cfg(i,name,settings):
    body=''.join(f'\t\t\t\t{k} = {v};\n' for k,v in settings)
    a(f'\t\t{i} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n')
common=[('ALWAYS_SEARCH_USER_PATHS','NO'),('CLANG_ENABLE_MODULES','YES'),('CLANG_ENABLE_OBJC_ARC','YES'),('ENABLE_STRICT_OBJC_MSGSEND','YES'),('ENABLE_USER_SCRIPT_SANDBOXING','YES'),('GCC_C_LANGUAGE_STANDARD','gnu17'),('IPHONEOS_DEPLOYMENT_TARGET','17.0'),('SDKROOT','iphoneos')]
cfg(PD,'Debug',common+[('DEBUG_INFORMATION_FORMAT','dwarf'),('ENABLE_TESTABILITY','YES'),('GCC_OPTIMIZATION_LEVEL','0'),('ONLY_ACTIVE_ARCH','YES'),('SWIFT_ACTIVE_COMPILATION_CONDITIONS','"DEBUG $(inherited)"'),('SWIFT_OPTIMIZATION_LEVEL','"-Onone"')])
cfg(PR,'Release',common+[('DEBUG_INFORMATION_FORMAT','"dwarf-with-dsym"'),('SWIFT_COMPILATION_MODE','wholemodule'),('VALIDATE_PRODUCT','YES')])
tgt=[('ASSETCATALOG_COMPILER_APPICON_NAME','AppIcon'),('CODE_SIGN_STYLE','Automatic'),('CURRENT_PROJECT_VERSION','1'),('DEVELOPMENT_TEAM','""'),('EG_PROXY_BASE_URL','""'),('GENERATE_INFOPLIST_FILE','YES'),('INFOPLIST_FILE','Info.plist'),('LD_RUNPATH_SEARCH_PATHS','"$(inherited) @executable_path/Frameworks"'),('MARKETING_VERSION','0.1.0'),('PRODUCT_BUNDLE_IDENTIFIER','app.echoguide.EchoGuide'),('PRODUCT_NAME','"$(TARGET_NAME)"'),('SWIFT_EMIT_LOC_STRINGS','YES'),('SWIFT_VERSION','5.0'),('TARGETED_DEVICE_FAMILY','1')]
cfg(TD,'Debug',tgt); cfg(TR,'Release',tgt)
a('/* End XCBuildConfiguration section */\n\n/* Begin XCConfigurationList section */\n')
for i,n,d,r in [(PCL,'PBXProject "EchoGuideApp"',PD,PR),(TCL,'PBXNativeTarget "EchoGuideApp"',TD,TR)]:
    a(f'\t\t{i} /* Build configuration list for {n} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{d} /* Debug */,\n\t\t\t\t{r} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n')
a('/* End XCConfigurationList section */\n\n/* Begin XCLocalSwiftPackageReference section */\n')
a(f'\t\t{PKG} /* XCLocalSwiftPackageReference ".." */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = ..;\n\t\t}};\n')
a('/* End XCLocalSwiftPackageReference section */\n\n/* Begin XCSwiftPackageProductDependency section */\n')
a(f'\t\t{DEP} /* EchoGuide */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = EchoGuide;\n\t\t}};\n')
a('/* End XCSwiftPackageProductDependency section */\n\t};\n'+f'\trootObject = {P} /* Project object */;\n}}\n')
open(os.path.join(ROOT,'EchoGuideApp.xcodeproj/project.pbxproj'),'w').write(''.join(L))
print(f"wrote project with {len(srcs)} sources")
