OS := $(shell uname)

ifeq ($(OS), Darwin)
# Run MacOS commands
CXX = g++-6 -m64
else
# check for Linux and run other commands
CXX = g++ -m64
endif

CXXFLAGS=-std=c++11 -Iobjs/ -I../Eigen/ -O3 -Wall

APP=dense_seq
OBJDIR=objs

APP_MAIN=main.cpp
SRCS=utils.cpp loadmtx.cpp mtxvec.cpp eigen.cpp qr.cpp
OBJS=$(patsubst %.cpp,$(OBJDIR)/%.o,$(SRCS))

.PHONY: dirs clean

default: dirs $(APP)

dirs:
	@/bin/mkdir -p $(OBJDIR)

clean:
	/bin/rm -rf $(OBJDIR) *~ $(APP) $(TEST)

test: dirs $(TEST)

$(TEST): $(TEST_MAIN) $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(TEST_MAIN) $(OBJS)

$(APP): $(APP_MAIN) $(OBJS)
	$(CXX) $(CXXFLAGS) -o $@ $(APP_MAIN) $(OBJS)

$(OBJDIR)/%.o: %.cpp $(DEPS)
	$(CXX) -MMD $(CXXFLAGS) -c -o $@ $<

-include $(OBJDIR)/*.d
