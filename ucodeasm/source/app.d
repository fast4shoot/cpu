import std.algorithm;
import std.file;
import std.stdio;
import pegged.grammar;

mixin(grammar("
uCode:
	Program < Line* eoi
	Spacing <- space*
	
	Line < LiteralAddress? Label? Instruction? Goto? :Comment? :eol?
	Comment <- :'#' (!eol .)*
	LiteralAddress <- :'at' :space+ ~(hexDigit+)
	Instruction <- (InstructionPart :space*)+
	InstructionPart <- 'ldInst' / 'ldData' / 'instJmp' / 'ipInc' / 'aluToDb' / 'dstToDb' / 'regWrite' / 'memClk' / 'dataToDb'
	Goto <- :'goto' :space+ identifier
	Label < identifier :':'
"));

int main(string[] args)
{
    auto text = readText(args[1]);
	auto pt = uCode(text);
	if (!pt.successful)
	{
		stderr.writeln(pt);
		return 1;
	}
	
	foreach (ref line; pt.children[0].children)
	{
		foreach (ref part; line.children)
		{
			part.name.writeln;
		}
	}
	return 0;
}
