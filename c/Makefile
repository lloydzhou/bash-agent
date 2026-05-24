CC      = gcc
CFLAGS  = -std=c11 -Wall -Wextra -Wno-unused-parameter -O2 -g
LDFLAGS = -lcurl -lpthread

BUILDDIR = build
SRCS = cagent.c agent.c store.c transport.c tools.c display.c \
       msgqueue.c readline.c linenoise.c json.c util.c protocol.c
OBJS = $(patsubst %.c,$(BUILDDIR)/%.o,$(SRCS))
TARGET = ../dist/cagent

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJS)
	@mkdir -p ../dist
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILDDIR)/%.o: %.c
	@mkdir -p $(BUILDDIR)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -rf $(BUILDDIR) $(TARGET)

# 依赖关系
$(BUILDDIR)/cagent.o: cagent.c agent.h store.h transport.h tools.h display.h msgqueue.h readline.h protocol.h util.h
$(BUILDDIR)/agent.o: agent.c agent.h store.h transport.h tools.h msgqueue.h protocol.h json.h util.h
$(BUILDDIR)/store.o: store.c store.h json.h util.h
$(BUILDDIR)/transport.o: transport.c transport.h json.h util.h
$(BUILDDIR)/tools.o: tools.c tools.h agent.h msgqueue.h protocol.h json.h util.h
$(BUILDDIR)/display.o: display.c display.h protocol.h util.h
$(BUILDDIR)/msgqueue.o: msgqueue.c msgqueue.h
$(BUILDDIR)/readline.o: readline.c readline.h msgqueue.h protocol.h util.h linenoise.h
$(BUILDDIR)/linenoise.o: linenoise.c linenoise.h
$(BUILDDIR)/json.o: json.c json.h
$(BUILDDIR)/util.o: util.c util.h
$(BUILDDIR)/protocol.o: protocol.c protocol.h util.h
