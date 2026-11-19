#!/bin/bash
# Build the C#-to-Zig translator (bin/cs2zig.dll) against the Roslyn assemblies that ship with the .NET SDK.
#   dotnet bin/cs2zig.dll ../../cs ../../zig/gen
# Written by Claude (Anthropic) for the SWMM6 ports; see AI-USE.md.
set -e
cd "$(dirname "$0")"
FW=$(ls -d /usr/lib/dotnet/shared/Microsoft.NETCore.App/8.* | head -1)
RB=$(ls -d /usr/lib/dotnet/sdk/*/Roslyn/bincore | head -1)
REFS=$(for f in $FW/*.dll; do case $(basename $f) in Microsoft.VisualBasic*|mscorlib.dll|netstandard.dll|System.Private.*) ;; *) echo -n "-r:$f ";; esac; done)
OUT=${OUT:-bin}
mkdir -p "$OUT"
nice -n 10 dotnet $RB/csc.dll -nologo -optimize+ -nullable:enable -nowarn:CS8600,CS8602,CS8603,CS8604,CS8618,CS8625 -langversion:latest -out:$OUT/cs2zig.dll $REFS -r:$FW/netstandard.dll -r:$FW/System.Private.CoreLib.dll \
  -r:$RB/Microsoft.CodeAnalysis.dll -r:$RB/Microsoft.CodeAnalysis.CSharp.dll Cs2Zig.cs ZigTypes.cs ZigFn.cs ZigExpr.cs
# the Roslyn assemblies are shared with the other translators in bin/: replace them only when they differ (a
# rewrite in place kills a translator running from bin/ with SIGBUS)
for f in Microsoft.CodeAnalysis.dll Microsoft.CodeAnalysis.CSharp.dll; do cmp -s $RB/$f $OUT/$f || cp $RB/$f $OUT/$f; done
printf '{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"%s"}}}' $(basename $FW) > $OUT/cs2zig.runtimeconfig.json
