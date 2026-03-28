Output demo.gif
Output demo.webm
Set FontSize 18
Set FontFamily "JetBrains Mono"
Set Width 1200
Set Height 800
Set Theme "Catppuccin Mocha"
Set Padding 12
Set Framerate 24

Hide
Type "cd /tmp && PATH=$MISE_PROJECT_ROOT/zig-out/bin:$PATH && clear"
Enter
Wait
Show

# Look up a class
Type "gdoc Node2D"
Sleep 0.5s
Enter
Sleep 2s
ScrollUp 50
Sleep 2s

# Look up a specific property
Type "gdoc Node2D.position"
Sleep 0.5s
Enter
Sleep 3s

# Look up a method
Type "gdoc String.format"
Sleep 0.5s
Enter
Sleep 2s
ScrollUp 30
Sleep 2s
