// 叶子序认领匹配回归:4 叶树 → SetSplitFactorLeaf 按先序叶子序号寻址 split。
// 树形:
//        R (LeftRight)
//       / \
//     A(UpDown)  L4
//     / \
//   L1   B(LeftRight)
//        / \
//      L2   L3
// 先序叶子序 [L1,L2,L3,L4];认领 = 左子树最右叶:L1→A, L2→B, L3→R, L4 无。
package main

import cv "../../src/canvas"
import "core:fmt"

main :: proc() {
	cv.CreateWindowTreeRoot()
	cv.SplitNewWindow(.LeftRight) // R;焦点 = 右叶(L4)
	cv.FocusMove(.Left) // → L1
	cv.SplitNewWindow(.UpDown) // A;焦点 = L2
	cv.SplitNewWindow(.LeftRight) // B;焦点 = L3

	root := cv.WindowTreeRoot() // = R
	r := cv.GetWindowTreeNode(root)
	a := cv.GetWindowTreeNode(r.left_son_id)
	b := cv.GetWindowTreeNode(a.right_son_id)
	fmt.printf("R=%d A=%d B=%d leaf_root_is_r=%v\n", root.id, r.left_son_id.id, a.right_son_id.id, root.id == 1)

	ok1 := cv.SetSplitFactorLeaf(1, 0.6)
	ok2 := cv.SetSplitFactorLeaf(2, 0.7)
	ok3 := cv.SetSplitFactorLeaf(3, 0.8)
	ok4 := cv.SetSplitFactorLeaf(4, 0.9)
	ok5 := cv.SetSplitFactorLeaf(5, 0.9)
	ok0 := cv.SetSplitFactorLeaf(0, 0.9)
	fmt.printf("leaf 1..3: %v %v %v  expect true true true\n", ok1, ok2, ok3)
	fmt.printf("leaf 4,5,0: %v %v %v  expect false false false\n", ok4, ok5, ok0)
	fmt.printf("A=%v B=%v R=%v  expect 0.6 0.7 0.8\n", a.split_factor, b.split_factor, r.split_factor)
}
