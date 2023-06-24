[CmdletBinding()]
param (
    [Parameter(Mandatory = $false)]
    [string] $ServerInstance = "localhost",

    [Parameter(Mandatory)]
    [string] $Database,

    [Parameter(Mandatory = $false)]
    [string] $DiagramSchema = "DiagramGeneration",

    [Parameter(Mandatory = $false)]
    [int] $ChunkSize = 20,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Mandatory", "Optional", "Strict")]
    [string] $Encrypt = "Optional"
)

############
# Preamble #
############

#requires -Version 5.1
#requires -Modules @{ ModuleName="SqlServer"; ModuleVersion="22.1.1" }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"


# New line regex. Output is normalised to use CRLF line endings
$UnixNewLineRegex = "(?<!`r)`n"
$NewLine = "`r`n"


#######################################
# Ensure dbo.sysdiagrams table exists #
#######################################

$DiagramTableExistsQuery = "
select
    case
        when exists (select 1 from sys.tables where name = 'sysdiagrams')
        then 1
    else 0
end as DiagramTableExists;"

$DiagramTableExists = Invoke-SqlCmd `
    -ServerInstance $ServerInstance `
    -Database $Database `
    -ApplicationIntent ReadOnly `
    -ConnectionTimeout 5 `
    -OutputAs DataTables `
    -QueryTimeout 5 `
    -Query $DiagramTableExistsQuery `
    -Encrypt $Encrypt

if ($DiagramTableExists[0].DiagramTableExists -eq 0) {
    Write-Host "The dbo.sysdiagrams table does not exist"
    exit 0
}


##############
# Main query #
##############

$Query = "
declare @ChunkSize int = `$(ChunkSize);

with
    L1 as (select 1 as A union all select 1),
    L2 as (select 1 as A from L1 a cross join L1 b),
    L3 as (select 1 as A from L2 a cross join L2 b),
    L4 as (select 1 as A from L3 a cross join L3 b),
    L5 as (select 1 as A from L4 a cross join L4 b),
    Numbers (Number) as (select row_number() over (order by (select 1)) from L5)
select *
from (
    select
        n.Number,
        datalength(d.definition) as NumBytes,
        d.name, d.principal_id, d.diagram_id, d.version,

        sys.fn_varbintohexsubstring(
            1,
            d.definition,
            case when n.Number = 1 then 1 else n.Number + 1 end,
            @ChunkSize)
        as Chunk
    from Numbers n
    cross join (
        select *
        from dbo.sysdiagrams
        where principal_id = 1 /* dbo-owned diagrams only */
    ) d
    where n.Number = 1 or n.Number % @ChunkSize = 0
) s
where Chunk is not null
order by name, Number;
"

# Normalise line endings (LF -> CRLF)
$Query = $Query -replace $UnixNewLineRegex, $NewLine


#####################
# Execute the query #
#####################

$Variables = @()
$Variables += "ChunkSize='$($ChunkSize)'"

$Results = Invoke-SqlCmd `
    -ServerInstance $ServerInstance `
    -Database $Database `
    -ApplicationIntent ReadOnly `
    -ConnectionTimeout 5 `
    -OutputAs DataTables `
    -QueryTimeout 30 `
    -Query $Query `
    -Variable $Variables `
    -Encrypt $Encrypt

if ($null -eq $Results) {
    Write-Host "No diagrams exist"
    exit 0
}


#################
# Group results #
#################
# Each set of grouped rows comprise one diagram.

$ResultsGrouped = $Results | Group-Object -Property diagram_id


############################################
# Generate each diagram creation procedure #
############################################

$GenerationProcedureNames = @()
$OutputSql = "
IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = N'$($DiagramSchema)')
    EXEC('CREATE SCHEMA [$($DiagramSchema)] AUTHORIZATION [dbo]');
GO

"

foreach ($Group in $ResultsGrouped) {
    $LastRow = $Group.Group[-1]

    $ProcedureName = "[$($DiagramSchema)].[$($LastRow.name)]"
    $GenerationProcedureNames += $ProcedureName

    $OutputSql += "
create or alter procedure $ProcedureName
as
begin
    set xact_abort, nocount on;

    if @@trancount > 0
    begin
        ; throw 50000, N'This procedure must not be executed within an open transaction.', 1;
        return 1;
    end

    begin try

        set transaction isolation level serializable;

        begin transaction;

        declare @DiagramWithNameExists bit = 0;
        declare @DiagramId int = 0;

        select
            @DiagramWithNameExists = 1,
            @DiagramId = diagram_id
        from dbo.sysdiagrams with (updlock, rowlock)
        where principal_id = $($LastRow.principal_id) and name = '$($LastRow.name)';

        if @DiagramWithNameExists = 0
        begin
            print N'Creating diagram ''$($LastRow.name)''...';

            declare @NewDiagramId table (Id int primary key);

            insert into dbo.sysdiagrams (name, principal_id, version, definition)
            output inserted.diagram_id
            into @NewDiagramId
            values ('$($LastRow.name)', $($LastRow.principal_id), 1, 0x);

            select @DiagramId = (select Id from @NewDiagramId);
        end
        else
        begin
            print N'Replacing diagram ''$($LastRow.name)''...';
            update dbo.sysdiagrams set definition = 0x where diagram_id = @DiagramId;
        end
"

    foreach ($Row in $Group.Group) {
        $OutputSql += "
        update dbo.sysdiagrams set definition.Write ($($Row.Chunk), null, 0) where diagram_id = @DiagramId;"

        if ($Row -eq $LastRow) {
            $OutputSql += $NewLine
        }
    }

    $OutputSql += "
        commit;

    end try
    begin catch
        if @@trancount > 0 rollback;
        throw;
    end catch

    return 0;
end;

go
"
}


#########################################
# Generate the InsertAll procedure code #
#########################################

$OutputSql += "
create or alter procedure [$($DiagramSchema)].[InsertAllDiagrams]
as
begin
    set xact_abort, nocount on;

    if @@trancount > 0
    begin
        ; throw 50000, N'This procedure must not be executed within an open transaction.', 1;
        return 1;
    end;

    begin try
"

$LastProcedureName = $GenerationProcedureNames[-1]

foreach ($ProcedureName in $GenerationProcedureNames) {
    $OutputSql += "        exec $($ProcedureName);"

    if ($ProcedureName -ne $LastProcedureName) {
        $OutputSql += $NewLine
    }
}

$OutputSql += "
    end try
    begin catch
        if @@trancount > 0 rollback;
        throw;
    end catch

    return 0;
end;

go
"


###########################
# Clean up generated code #
###########################

# Trim empty line at start of generated SQL
$OutputSql = $OutputSql.TrimStart()

# Normalise line endings (LF -> CRLF)
$OutputSql = $OutputSql -replace $UnixNewLineRegex, $NewLine


#######################
# Write generated SQL #
#######################
$OutputSql
