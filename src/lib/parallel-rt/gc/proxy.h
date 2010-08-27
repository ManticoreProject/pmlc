
typedef struct {
	Value_t	proxyObj;	// proxy object in the global heap
	Value_t	localObj;	// local-heap object that the proxy represents.
} ProxyTblEntry_t;


extern Value_t createProxy (VProc_t *vp, Value_t fls);
extern void isProxy (VProc_t *vp,int zahl);
extern void deleteProxy (VProc_t *vp,int zahl);
extern void createList (VProc_t *vp);
extern int isFree (VProc_t *vp);