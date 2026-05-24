CC      = gcc
CFLAGS  = -std=c11 -Wall -Wextra -Wno-unused-parameter -O2 -g
LDFLAGS = -lcurl -lpthread

SRCS = cagent.c agent.c store.c transport.c tools.c display.c \
       msgqueue.c readline.c linenoise.c json.c util.c protocol.c
OBJS = $(SRCS:.c=.o)
TARGET = ../dist/cagent

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJS)
	@mkdir -p ../dist
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(TARGET)

# 依赖关系
cagent.o: cagent.c agent.h store.h transport.h tools.h display.h msgqueue.h readline.h protocol.h util.h
agent.o: agent.c agent.h store.h transport.h tools.h msgqueue.h protocol.h json.h util.h
store.o: store.c store.h json.h util.h
transport.o: transport.c transport.h json.h util.h
tools.o: tools.c tools.h agent.h msgqueue.h protocol.h json.h util.h
display.o: display.c display.h protocol.h util.h
msgqueue.o: msgqueue.c msgqueue.h
readline.o: readline.c readline.h msgqueue.h protocol.h util.h linenoise.h
linenoise.o: linenoise.c linenoise.h
json.o: json.c json.h
util.o: util.c util.h
protocol.o: protocol.c protocol.h util.h
