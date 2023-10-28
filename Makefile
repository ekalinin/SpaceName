release:
	git tag `grep "version = " init.lua | grep -o -E '[0-9]\.[0-9]'`
	git push --tags origin main
