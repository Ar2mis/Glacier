#!/usr/bin/env python3
"""Deterministic native targets; no third-party project generator or signing secrets."""
from pathlib import Path
import argparse
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]

def identifier(value):
    return hashlib.sha256(value.encode()).hexdigest()[:24].upper()

def encode(value, depth=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('    '*(depth+1) + json.dumps(k) + ' = ' + encode(v,depth+1) + ';\n' for k,v in value.items()) + '    '*depth + '}'
    if isinstance(value, list):
        return '(' + ', '.join(encode(v,depth) for v in value) + (',' if value else '') + ')'
    if isinstance(value, int): return str(value)
    return json.dumps(value)

def project_files():
    objects = {}
    refs = {}
    def add(key, isa, **values):
        uid=identifier(key); objects[uid]={'isa':isa,**values}; return uid
    def file(path, kind):
        if path not in refs: refs[path]=add('file:'+path,'PBXFileReference',lastKnownFileType=kind,path=path,sourceTree='<group>')
        return refs[path]
    package=add('package','XCLocalSwiftPackageReference',relativePath='.')
    resources=['Resources/Assets.xcassets','Resources/PrivacyInfo.xcprivacy','THIRD_PARTY_NOTICES.txt','PRIVACY_POLICY.md','SUPPORT.md']
    resource_types=['folder.assetcatalog','text.xml','text','net.daringfireball.markdown','net.daringfireball.markdown']
    products=[]; targets=[]; schemes={}
    for name,config,mac,product in [('GlacierMac','MacStore',True,'Glacier'),('GlacierMacDev','MacDev',True,'Glacier Dev'),('GlacierIOS','iOS',False,'Glacier')]:
        paths=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'Sources').glob('*.swift')) if mac else ['iOS/GlacierMobileApp.swift','Sources/GPTTranslator.swift','Sources/LectureArchive.swift','Sources/WordExporter.swift']
        sources=[add(name+':source:'+p,'PBXBuildFile',fileRef=file(p,'sourcecode.swift')) for p in paths]
        assets=[add(name+':resource:'+p,'PBXBuildFile',fileRef=file(p,k)) for p,k in zip(resources,resource_types)]
        dependency=add(name+':core','XCSwiftPackageProductDependency',package=package,productName='GlacierCore')
        lib=add(name+':framework','PBXBuildFile',productRef=dependency)
        phases=[add(name+':sources','PBXSourcesBuildPhase',buildActionMask=2147483647,files=sources,runOnlyForDeploymentPostprocessing=0),add(name+':frameworks','PBXFrameworksBuildPhase',buildActionMask=2147483647,files=[lib],runOnlyForDeploymentPostprocessing=0),add(name+':resources','PBXResourcesBuildPhase',buildActionMask=2147483647,files=assets,runOnlyForDeploymentPostprocessing=0)]
        configs=[]
        for mode in ['Debug','Release']:
            configs.append(add(name+':'+mode,'XCBuildConfiguration',name=mode,baseConfigurationReference=file('Config/'+config+'.xcconfig','text.xcconfig'),buildSettings={'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym'}))
        configurations=add(name+':configs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
        app=add(name+':product','PBXFileReference',explicitFileType='wrapper.application',includeInIndex=0,path=product+'.app',sourceTree='BUILT_PRODUCTS_DIR'); products.append(app)
        target=add(name,'PBXNativeTarget',name=name,productName=product,productType='com.apple.product-type.application',productReference=app,buildConfigurationList=configurations,buildPhases=phases,buildRules=[],dependencies=[],packageProductDependencies=[dependency]);targets.append(target)
        ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}.app" BlueprintName="{name}" ReferencedContainer="container:Glacier.xcodeproj"/>'
        schemes[f'Glacier.xcodeproj/xcshareddata/xcschemes/{name}.xcscheme']=f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"/>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    for p in ['Config/Signing.xcconfig','Config/Shared.xcconfig']: file(p,'text.xcconfig')
    for p in ['Config/Mac-Info.plist','Config/iOS-Info.plist','Config/GlacierMac.entitlements']: file(p,'text.plist.xml')
    product_group=add('products','PBXGroup',name='Products',children=products,sourceTree='<group>')
    main=add('main','PBXGroup',children=list(refs.values())+[product_group],sourceTree='<group>')
    configs=[add('project:'+mode,'XCBuildConfiguration',name=mode,buildSettings={'CLANG_ENABLE_MODULES':'YES','SWIFT_VERSION':'5.0'}) for mode in ['Debug','Release']]
    configlist=add('project:configs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
    project=add('project','PBXProject',attributes={'LastUpgradeCheck':'2600','TargetAttributes':{targets[0]:{'SystemCapabilities':{'com.apple.Sandbox':{'enabled':1},'com.apple.HardenedRuntime':{'enabled':1}}}}},buildConfigurationList=configlist,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','zh-Hans','Base'],mainGroup=main,packageReferences=[package],productRefGroup=product_group,projectDirPath='',projectRoot='',targets=targets)
    schemes['Glacier.xcodeproj/project.pbxproj']='// !$*UTF8*$!\n'+encode({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project})+'\n'
    return schemes

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    for path,content in project_files().items():
        target=ROOT/path
        if args.check:
            if not target.exists() or target.read_text()!=content: raise SystemExit(f'Regenerate Xcode project: {path}')
        else: target.parent.mkdir(parents=True,exist_ok=True);target.write_text(content)
    print('PASS: native Xcode target definitions' if args.check else 'Generated GlacierMac, GlacierMacDev and GlacierIOS')
