#include<bits/stdc++.h>
using namespace std;

struct Bar{
	
	int a, b;

	Bar(int x, int y){
		a = x;
		b = y;
	}
	
	~Bar(){
		a = 0;
		b = 0;
	}

};

int main(){
	Bar bar = Bar(1, 1);
	return 0;
}
