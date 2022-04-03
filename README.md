# Get-SSMSDiagramCode

This PowerShell script generates stored procedures that can recreate SSMS diagrams when executed.
The generated procedures will either create the diagram from scratch, or replace the diagram.

The generated procedure code is written in a manner that allows all generated procedures to live within a single `*.sql` file.

One possible use of the tool is to generate the content of a `*.sql` file that is included within a `SqlProj` (SSDT) project.

You could then include the following code within the SSDT project's post-deployment script to deploy diagrams during each DACPAC deployment.

Sample post-deployment script code:
```sql
exec DiagramGeneration.InsertAllDiagrams;
```

## Usage

At a minimum you'll need to specify the name of a database running on localhost:
```powershell
.\Get-SSMSDiagramCode.ps1 -Database StackOverflow2013
```

You can also connect to an instance by specifying the `-ServerInstance` argument:
```powershell
.\Get-SSMSDiagramCode.ps1 -ServerInstance localhost -Database StackOverflow2013
```

By default, each stored procedure will be generated so that it belongs to a schema named `DiagramGeneration`.

If you wish to place it in a different schema you can use the `-DiagramSchema` argument:
```powershell
.\Get-SSMSDiagramCode.ps1 -Database StackOverflow2013 -DiagramSchema dbo
```

You can also specify the chunk size (number of bytes per generated `update` statement) using the `-ChunkSize` argument:
```powershell
.\Get-SSMSDiagramCode.ps1 -Database StackOverflow2013 -ChunkSize 32
```

By default the generated code will be written to the PowerShell terminal. You can redirect the generated code elsewhere - such as a file - using the `Out-File` cmdlet. For example:
```powershell
.\Get-SSMSDiagramCode.ps1 -Database StackOverflow2013 | Out-File -FilePath generated.sql -Encoding utf8
```
