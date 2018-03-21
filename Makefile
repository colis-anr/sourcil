.PHONY: build install uninstall doc clean

build:
	jbuilder build @install

install:
	jbuilder install

uninstall:
	jbuilder uninstall

doc:
	jbuilder build @doc
	ln -s _build/default/_doc doc

clean:
	jbuilder clean
	rm -f doc
