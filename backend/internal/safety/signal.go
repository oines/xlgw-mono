package safety

import "strings"

// ExplicitSignal matches a small set of direct expressions for manual review or a local safety reply.
func ExplicitSignal(text string) bool {
	text = strings.ToLower(strings.Join(strings.Fields(text), ""))
	signals := []string{"我不想活了", "我想自杀", "我要自杀", "我准备自杀", "我想结束生命",
		"我想结束自己的生命", "我要伤害自己", "我要杀了他", "我要杀了她",
		"suicideplan", "iwanttokillmyself", "i'mgoingtokillmyself", "iwanttoendmylife"}
	for _, marker := range signals {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}
