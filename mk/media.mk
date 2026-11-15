# Targets for the clips of the launcher on the website and in the README (scenarios/media,
# site/media). The Makefile includes every mk/*.mk, so add targets here without editing it.
# Document each new target with a "#   make <target>  <what it does>" line, which make help prints.
#
#   make media            record every storyboard in scenarios/media and publish the clips to site/media;
#                         ONLY=hero-dark,actions-dark limits it, PUBLISH=0 keeps site/media as it is

.PHONY: media

# Each clip holds key status for five to nine seconds, so it waits for two idle minutes first and
# up to 90 minutes in all. scenarios/media/record.sh builds its own app in build/media.
media: core
	@EXECUTABLE=$(EXECUTABLE) $(ROOT)/scenarios/media/record.sh $(if $(ONLY),only=$(ONLY)) \
	    $(if $(PUBLISH),publish=$(PUBLISH))
