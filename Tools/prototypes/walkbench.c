#define _DARWIN_C_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/resource.h>
#include <sys/vnode.h>

typedef struct { char **v; size_t n, cap; } Stack;
static void push(Stack *s, const char *p){
  if(s->n==s->cap){ s->cap = s->cap? s->cap*2 : 1024; s->v = realloc(s->v, s->cap*sizeof(char*)); }
  s->v[s->n++] = strdup(p);
}
static char *pop(Stack *s){ return s->n? s->v[--s->n] : NULL; }

static unsigned long long n_files=0, n_dirs=0, n_err=0, sum_alloc=0, sum_logical=0, n_hardlink=0, n_dataless=0;

#define BUFSZ (256*1024)

static void walk_dir(const char *path, Stack *st){
  int fd = open(path, O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
  if(fd < 0){ n_err++; return; }
  struct attrlist al; memset(&al,0,sizeof al);
  al.bitmapcount = ATTR_BIT_MAP_COUNT;
  al.commonattr  = ATTR_CMN_RETURNED_ATTRS|ATTR_CMN_NAME|ATTR_CMN_DEVID|ATTR_CMN_OBJTYPE
                 | ATTR_CMN_MODTIME|ATTR_CMN_FLAGS|ATTR_CMN_FILEID|ATTR_CMN_ERROR;
  al.fileattr    = ATTR_FILE_LINKCOUNT|ATTR_FILE_TOTALSIZE|ATTR_FILE_ALLOCSIZE;
  char *buf = malloc(BUFSZ);
  int count;
  while((count = getattrlistbulk(fd, &al, buf, BUFSZ, 0)) > 0){
    char *entry = buf;
    for(int i=0;i<count;i++){
      char *f = entry;
      uint32_t entlen; memcpy(&entlen, f, 4); f += 4;
      attribute_set_t ret; memcpy(&ret, f, sizeof ret); f += sizeof ret;
      const char *name=NULL; uint32_t objtype=0, cmnflags=0, err=0; 
      uint64_t alloc=0, logical=0; uint32_t linkcount=0;
      if(ret.commonattr & ATTR_CMN_NAME){
        attrreference_t ar; memcpy(&ar,f,sizeof ar); name = f + ar.attr_dataoffset; f += sizeof ar;
      }
      if(ret.commonattr & ATTR_CMN_DEVID) f += sizeof(dev_t);
      if(ret.commonattr & ATTR_CMN_OBJTYPE){ memcpy(&objtype,f,4); f += 4; }
      if(ret.commonattr & ATTR_CMN_MODTIME) f += sizeof(struct timespec);
      if(ret.commonattr & ATTR_CMN_FLAGS){ memcpy(&cmnflags,f,4); f += 4; }
      if(ret.commonattr & ATTR_CMN_FILEID) f += 8;
      if(ret.commonattr & ATTR_CMN_ERROR){ memcpy(&err,f,4); f += 4; }
      if(ret.fileattr & ATTR_FILE_LINKCOUNT){ memcpy(&linkcount,f,4); f += 4; }
      if(ret.fileattr & ATTR_FILE_TOTALSIZE){ memcpy(&logical,f,8); f += 8; }
      if(ret.fileattr & ATTR_FILE_ALLOCSIZE){ memcpy(&alloc,f,8); f += 8; }

      if(err){ n_err++; entry += entlen; continue; }
      if(name && (!strcmp(name,".")||!strcmp(name,".."))){ entry += entlen; continue; }
      if(cmnflags & SF_DATALESS) n_dataless++;

      if(objtype == VDIR){
        n_dirs++;
        if(name && !(cmnflags & SF_FIRMLINK)){
          char child[4096];
          snprintf(child,sizeof child,"%s/%s",path,name);
          push(st, child);
        }
      } else if(objtype == VREG){
        n_files++;
        if(linkcount > 1) n_hardlink++;
        sum_alloc += alloc; sum_logical += logical;
      }
      entry += entlen;
    }
  }
  free(buf); close(fd);
}

int main(int argc,char**argv){
  if(argc<2){ fprintf(stderr,"usage: walkbench <path>\n"); return 2; }
  // CRITICAL: never materialize iCloud dataless placeholders while scanning.
  setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                 IOPOL_MATERIALIZE_DATALESS_FILES_OFF);
  struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0);
  Stack st = {0}; push(&st, argv[1]);
  char *p;
  while((p = pop(&st))){ walk_dir(p, &st); free(p); }
  clock_gettime(CLOCK_MONOTONIC,&t1);
  double el = (t1.tv_sec-t0.tv_sec) + (t1.tv_nsec-t0.tv_nsec)/1e9;
  unsigned long long total = n_files+n_dirs;
  printf("path            : %s\n", argv[1]);
  printf("files           : %llu\n", n_files);
  printf("dirs            : %llu\n", n_dirs);
  printf("errors(skipped) : %llu\n", n_err);
  printf("hardlinked      : %llu\n", n_hardlink);
  printf("dataless        : %llu\n", n_dataless);
  printf("alloc (physical): %.2f GiB\n", sum_alloc/1073741824.0);
  printf("logical         : %.2f GiB\n", sum_logical/1073741824.0);
  printf("elapsed         : %.3f s\n", el);
  printf("throughput      : %.0f entries/sec\n", total/el);
  return 0;
}
