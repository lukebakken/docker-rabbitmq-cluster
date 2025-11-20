.PHONY: clean
clean:
	$(CURDIR)/mvnw clean

.PHONY: compile
compile:
	$(CURDIR)/mvnw compile

.PHONY: run
run: compile
	$(CURDIR)/mvnw exec:java '-Dexec.mainClass=com.mycompany.app.App' "-Dexec.args=$(ARGS)"
