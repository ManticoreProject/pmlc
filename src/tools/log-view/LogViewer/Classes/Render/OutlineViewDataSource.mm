
/** \file OutlineViewDataSource.mm
  * \author Korei Klein
  * \date 7/27/09
  *
  */

#import "OutlineViewDataSource.h"
#import "log-desc.hxx"
#import "Exceptions.h"
#import "Box.h"
#import "LogDoc.h"


#define DEFAULT_ENABLED_STATE ( [NSNumber numberWithInt:1] )


@implementation OutlineViewDataSource



- (OutlineViewDataSource *)initWithLogDesc:(struct LogFileDesc *)descVal
				    logDoc:logDocVal
{
    if (![super init]) return nil;
    desc = descVal;
    root = desc->Root();
    logDoc = logDocVal;
    map = [[NSMutableDictionary alloc] init];
    boxes = [[NSMutableArray alloc] init];
    // NSNumber *n = [map objectForKey:@"All Events"];
   // NSLog(@"number n = %@, (s == s) = %d", n, [@"mee" isEqual:@"me"]);
    // Group *cppRoot = desc->Root(); //  [Exceptions raise:@"OutlineVieDataSource: how does one find the root?"];

    /*
    switch(cppRoot->Kind())
    {
	case EVENT_GROUP:
	    root = [[InternalGroup alloc] initWithCppGroup:cppRoot];
	    break;
	case STATE_GROUP:
	case INTERVAL_GROUP:
	case DEPENDENT_GROUP:
	    root = [[LeafGroup alloc] initWithCppGroup:cppRoot];
	    break;
	default:
	    [Exceptions raise:@"OutlineViewDataSource: root has no known kind"];
    }
     */
    return self;
}


- (id)outlineView:(NSOutlineView *)outlineView
	    child:(NSInteger)index
	   ofItem:(id)item
{
    // NSLog(@"OutlineViewDataSource: returning child of item");
    if (item == nil)
    {
	if (index != 0)
	{
	    [Exceptions
	       raise:@"OutlineVieDataSource: nil has one child, asked for a child of index != 0"];
	}
	else // index == 0
	{
	    NSLog(@"returning root");
	    Box *b = [Box box:(void *)root];
	    [boxes addObject:b];
	    return b;
	}
    }
    Group *g = (Group *)[((Box *)item) unbox];
    if (g->Kind() != EVENT_GROUP)
	[Exceptions raise:@"OutlineViewDataSource: asked for the child of a leaf node"];
    EventGroup *G = (EventGroup *)g;
    Box *b = [Box box:(void *)(G->Kid(index))];
    [boxes addObject:b];
    return (Box *)b;
    /*
    if (((ObjCGroup *)item).kind != EVENT_GROUP)
	[Exceptions raise:@"OutlineVieDataSource was asked for a child of a leaf node"];
    return [item kid:index];
     */
}

- (BOOL)outlineView:(NSOutlineView *)outlineView
   isItemExpandable:(id)item
{
    if (item == nil)
    {
	[Exceptions raise:@"OutlineVieDataSource: asked if nil was expandable"];
    }
    Group *g = (Group *)[((Box *)item) unbox];
    if (g->Kind() == EVENT_GROUP)
    {
	return YES;
    }
    else
    {
	return NO;
    }
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView
  numberOfChildrenOfItem:(id)item
{
    if (item == nil) return 1;
    Group *g = (Group *)[((Box *)item) unbox];
    if (g->Kind() != EVENT_GROUP)
    {
	[Exceptions raise:@"OutlineVieDataSource was asked for a child of a leaf node"];
	return -1;
    }
    else
    {
	EventGroup *G = (EventGroup *)g;
	//NSLog(@"returning that group %s has %d kids", G->Desc(), G->NumKids());
	return G->NumKids();
    }
}

	     -(id)outlineView:(NSOutlineView *)outlineView
    objectValueForTableColumn:(NSTableColumn *)tableColumn
		       byItem:(id)item
{
    if (item == nil)
	[Exceptions raise:@"nil has no valueForTableColumn"];
    NSNumber *ident = tableColumn.identifier;
    Box *b = (Box *)item;
    // NSLog(@"Box is %@", b);
    Group *g = (Group *)[b unbox];
    if (ident)
    {
	if (ident.intValue == 0)
	{
	    NSString *s = [NSString stringWithCString:g->Desc()
					     encoding:NSASCIIStringEncoding];
	    // NSLog(@"OutlineViewDataSource: returning the description of an item: %@", s);
	    return s;
	}
	else if (ident.intValue == 1)
	{
	   // NSLog(@"outlineviewdatasource, returning enabled state of g");
	    return [self enabled:g];
	}
	else
	{
	    [Exceptions raise:@"Table Column lacks a suitable identifier"];
	}
    }
    [Exceptions raise:@"Table Column's identifier was nil"];
    return [NSNumber numberWithInt:-1];
}

/// Modify the mapping, do not follow any logic for propogating the effect of a change
- (void)mapState:(NSNumber *)n forGroup:(Group *)g
{
    const char *s = g->Desc();
    NSString *S = [NSString stringWithCString:s encoding:NSASCIIStringEncoding];
    S = [[NSString alloc] initWithString:S];
    //NSLog(@"setting object %@, for key %@ in map", n, S);
    [map setObject:n forKey:S];
}

/// Change the state of theparent (g) and all its ancestors to reflect
/// the states of their descendents
- (void)setParentByKids:(Group *)g
{
    if (g == NULL) return;
    if (g->Kind() != EVENT_GROUP)
    {
	[Exceptions raise:@"Found a parent which has no children.  Impossible!"];
    }
    EventGroup *parent = (EventGroup *)g;
    if (parent->NumKids() == 0)
    {
	[Exceptions raise:@"setParentByKids was called with a childless group"];
    }
    BOOL found_0 = 0; // 1 iff any descendents are 0
    BOOL found_1 = 0; // 1 iff any descendents are 1
    for (int i = 0; i < parent->NumKids(); ++i)
    {
	int cur_case = [self enabled:parent->Kid(i)].intValue;
	switch (cur_case)
	{
	    case 0:
		found_0 = 1;
		break;
	    case 1:
		found_1 = 1;
		break;
	    case -1:
		found_0 = found_1 = 1;
		break;
	    default:
		NSLog(@"wierd case %d", cur_case);
		[Exceptions raise:@"failure impossible case"];
	}
    }
    NSNumber *stateVal;
    if (found_0 && !found_1)
    {
	stateVal = [NSNumber numberWithInt:0];
    }
    else if (!found_0 && found_1)
    {
	stateVal = [NSNumber numberWithInt:1];
    }
    else if (found_0 && found_1)
    {
	stateVal = [NSNumber numberWithInt:-1];
    }
    else
    {
	[Exceptions raise:@"Failure, impossible case"];
    }
    [self mapState:stateVal forGroup:g];
    
    
    [self setParentByKids:parent->Parent()]; //< the grandparent
}



/// Modify the mapping, follow the logic for propogating the effect of the change
- (void)setButtonState:(NSNumber *)n forGroup:(Group *)g
{
    [self mapState:n forGroup:g];
    // All children receive the same state as the parent if the parent is not mixed
    if (n.intValue != -1 && (g->Kind() == EVENT_GROUP))
    {
	EventGroup *G = (EventGroup *)g;
	for (int i = 0; i < G->NumKids(); ++i)
	{
	    [self setButtonState:n forGroup:G->Kid(i)];
	}
    }
    
	
    [self setParentByKids:g->Parent()];
}
- (void)outlineView:(NSOutlineView *)outlineView
     setObjectValue:(id)object
     forTableColumn:(NSTableColumn *)tableColumn
	     byItem:(id)item
{
    if (item == nil)
	[Exceptions raise:@"OutlineView: passed a nil item to set"];
    NSNumber *ident = tableColumn.identifier;
    if (ident == nil)
	[Exceptions raise:@"Table column lacks an identifier"];
    if (ident.intValue != 1)
	[Exceptions raise:@"Can't edit a table column whose identifier is not 1"];
    Group *g = (Group *)([((Box *)item) unbox]);
    NSNumber *n = (NSNumber *)object;
    
    // Can't allow users to set the button to mixed
    // The button can only be set to mixed internally
    if (n.intValue == -1)
    {
	[self setButtonState:[NSNumber numberWithInt:1] forGroup:g];
    }
    else
    {
	[self setButtonState:n forGroup:g];
    }

    outlineView.needsDisplay = true;
    [logDoc flush];
}

- (NSNumber *)enabled:(struct Group *)g
{
    const char *s = g->Desc();
   // NSLog(@"%@ looking up enabled state for group %s in map %@", self, s, map);
    NSString *S = [NSString stringWithCString:s encoding:NSASCIIStringEncoding];
    NSString *R = [[NSString alloc] initWithString:S];
    // NSLog(@"map = %@", map);
    NSNumber *ret = [map objectForKey:R];
    
    //if (ret) NSLog(@"looked up %@ to find %@ in enabled map", S, ret);
    if (ret == nil)
    {
	return DEFAULT_ENABLED_STATE;
    }
    else
    {
	//NSLog(@"Returning enabled state %@", ret);
	return ret;
    }
}


@end



