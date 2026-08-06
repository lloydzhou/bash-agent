CC      = gcc
CFLAGS  = -std=c11 -Wall -Wextra -Wno-unused-parameter -O2 -g -D_GNU_SOURCE -Ivendor/linenoise
LDFLAGS = -lcurl -lpthread

BUILDDIR = build
SRCS = cagent.c agent.c store.c transport.c tools.c display.c \
       msgqueue.c readline.c json.c util.c protocol.c
VENDOR_SRCS = vendor/linenoise/linenoise.c
OBJS = $(patsubst %.c,$(BUILDDIR)/%.o,$(SRCS)) $(patsubst %.c,$(BUILDDIR)/%.o,$(VENDOR_SRCS))
TARGET = ../dist/cagent

.PHONY: all clean test-continue test-transport

all: $(TARGET)

# 自动从 tools.json 生成嵌入头文件
tools_embed.h: tools.json
	@echo "  GEN     tools_embed.h"
	@{ echo '/* tools.json 编译时嵌入 — 由 Makefile 自动生成，勿手动编辑 */'; \
	   echo 'const char embedded_tools_json[] = {'; \
	   xxd -i < tools.json; \
	   echo ', 0x00 };'; \
	   echo "const unsigned int embedded_tools_json_len = $$(wc -c < tools.json);"; \
	} > tools_embed.h

$(TARGET): $(OBJS)
	@mkdir -p ../dist
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILDDIR)/%.o: %.c tools_embed.h
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -rf $(BUILDDIR) $(TARGET) tools_embed.h test_classify test_continue test_transport

test-classify: test_classify.c
	$(MAKE) $(BUILDDIR)/tools_test.o CFLAGS="$(CFLAGS) -DTEST_CLASSIFY" OBJS="$(filter-out $(BUILDDIR)/cagent.o $(BUILDDIR)/tools.o,$(OBJS)) $(BUILDDIR)/tools_test.o"
	$(CC) $(CFLAGS) -DTEST_CLASSIFY -o test_classify test_classify.c $(filter-out $(BUILDDIR)/cagent.o $(BUILDDIR)/tools.o,$(OBJS)) $(BUILDDIR)/tools_test.o $(LDFLAGS)
	@./test_classify

test-continue: test_continue.c store.c util.c json.c
	$(CC) $(CFLAGS) -o test_continue test_continue.c store.c util.c json.c
	@./test_continue

test-transport: test_transport.c transport.c util.c json.c
	$(CC) $(CFLAGS) -o test_transport test_transport.c util.c json.c $(LDFLAGS)
	@./test_transport

$(BUILDDIR)/tools_test.o: tools.c tools.h agent.h msgqueue.h protocol.h json.h util.h
	$(CC) $(CFLAGS) -DTEST_CLASSIFY -c -o $@ tools.c

# 依赖关系
$(BUILDDIR)/cagent.o: cagent.c agent.h store.h transport.h tools.h display.h msgqueue.h readline.h protocol.h util.h
$(BUILDDIR)/agent.o: agent.c agent.h tools_embed.h store.h transport.h tools.h msgqueue.h protocol.h json.h util.h
$(BUILDDIR)/store.o: store.c store.h json.h util.h
$(BUILDDIR)/transport.o: transport.c transport.h json.h util.h
$(BUILDDIR)/tools.o: tools.c tools.h agent.h msgqueue.h protocol.h json.h util.h
$(BUILDDIR)/display.o: display.c display.h protocol.h util.h
$(BUILDDIR)/msgqueue.o: msgqueue.c msgqueue.h
$(BUILDDIR)/readline.o: readline.c readline.h msgqueue.h protocol.h util.h vendor/linenoise/linenoise.h
$(BUILDDIR)/json.o: json.c json.h
$(BUILDDIR)/util.o: util.c util.h
$(BUILDDIR)/protocol.o: protocol.c protocol.h util.h

# vendor (submodule)
$(BUILDDIR)/vendor/linenoise/linenoise.o: vendor/linenoise/linenoise.c vendor/linenoise/linenoise.h
