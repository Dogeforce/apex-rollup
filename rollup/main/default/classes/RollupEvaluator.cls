public without sharing abstract class RollupEvaluator implements Rollup.Evaluator {
  private static final String RELATIONSHIP_FIELD_DELIMITER = '\\.';

  public abstract Boolean matches(Object calcItem);

  public static RollupEvaluator getEvaluator(Rollup__mdt rollupMetadata, Map<Id, SObject> oldCalcItems, SObjectType sObjectType) {
    Boolean isChangedFieldEval = String.isNotBlank(rollupMetadata.ChangedFieldsOnCalcItem__c);
    Boolean isWhereClauseEval = String.isNotBlank(rollupMetadata.CalcItemWhereClause__c);
    if (isChangedFieldEval && isWhereClauseEval) {
      return new CombinedEvaluator(rollupMetadata, oldCalcItems, sObjectType);
    } else if (isChangedFieldEval) {
      return new SObjectChangedFieldEvaluator(rollupMetadata.ChangedFieldsOnCalcItem__c.split(','), oldCalcItems);
    } else if (isWhereClauseEval) {
      return new WhereFieldEvaluator(rollupMetadata.CalcItemWhereClause__c, sObjectType);
    }
    return null;
  }

  private class CombinedEvaluator extends RollupEvaluator {
    private final RollupEvaluator changedFiedEval;
    private final RollupEvaluator whereClauseEval;
    public CombinedEvaluator(Rollup__mdt rollupMetadata, Map<Id, SObject> oldCalcItems, SObjectType sObjectType) {
      this.changedFiedEval = new SObjectChangedFieldEvaluator(rollupMetadata.ChangedFieldsOnCalcItem__c.split(','), oldCalcItems);
      this.whereClauseEval = new WhereFieldEvaluator(rollupMetadata.CalcItemWhereClause__c, sObjectType);
    }

    public override Boolean matches(Object calcItem) {
      return this.changedFiedEval.matches(calcItem) && this.whereClauseEval.matches(calcItem);
    }
  }

  public class SObjectChangedFieldEvaluator extends RollupEvaluator {
    private final List<String> changedFieldNames;
    private final Map<Id, SObject> oldRecordsMap;
    public SObjectChangedFieldEvaluator(List<String> changedFieldNames, Map<Id, SObject> oldRecordsMap) {
      this.changedFieldNames = changedFieldNames;
      this.oldRecordsMap = oldRecordsMap;
    }

    public override Boolean matches(Object calcItem) {
      SObject calcSObject = (SObject) calcItem;
      SObject oldRecord = oldRecordsMap.get(calcSObject.Id);
      Boolean matches = this.changedFieldNames.isEmpty() || this.oldRecordsMap == null;
      for (String fieldName : this.changedFieldNames) {
        // need to trim because list can be comma-separated with leading/trailing spaces
        if (calcSObject.get(fieldName.trim()) != oldRecord.get(fieldName.trim())) {
          matches = true;
          break;
        }
      }
      return matches;
    }
  }

  public class WhereFieldEvaluator extends RollupEvaluator {
    private final String whereClause;
    // totally not obvious ranking going on here - it's absolutely imperative that
    // the two-word conditions go first; otherwise replacing will fail on the whole string
    // due to casing issues (NOT like, NOT in). I could make those be part of the map, too,
    // but that seems even worse than the pseudo-ranking going on here
    private final Map<String, String> conditionMapping = new Map<String, String>{
      'not in' => '!=',
      'NOT IN' => '!=',
      'not like' => '!like',
      'NOT LIKE' => '!like',
      '<>' => '!=',
      'in' => '=',
      'IN' => '=',
      'LIKE' => 'like'
    };
    private final List<ConditionalGrouping> conditionalGroupings = new List<ConditionalGrouping>();

    public WhereFieldEvaluator(String whereClause, SObjectType calcItemSObjectType) {
      if (whereClause == null) {
        whereClause = '';
      }
      for (String conditionKey : this.conditionMapping.keySet()) {
        whereClause = whereClause.replace(conditionKey, conditionMapping.get(conditionKey));
      }
      this.whereClause = whereClause;
      this.createConditions(calcItemSObjectType);
    }

    public List<String> getRelationshipFieldNames() {
      List<String> fieldNames = new List<String>();
      for (ConditionalGrouping conditionalGrouping : this.conditionalGroupings) {
        for (WhereFieldCondition condition : conditionalGrouping.innerConditions) {
          if (fieldNames.contains(condition.fieldName) == false) {
            fieldNames.add(condition.fieldName);
            if (condition.fieldName.contains('.')) {
              List<String> relationshipNames = condition.fieldName.split(RELATIONSHIP_FIELD_DELIMITER);
              String priorVal = '';
              for (String relationshipName : relationshipNames) {
                if (String.isNotBlank(priorVal)) {
                  priorVal += '.';
                }
                priorVal += relationshipName.trim();
              }
              if (fieldNames.contains(priorVal) == false) {
                fieldNames.add(priorVal);
              }
            }
          }
        }
      }
      return fieldNames;
    }

    public override Boolean matches(Object calcItem) {
      Boolean matches = calcItem instanceof SObject;
      if (matches) {
        for (ConditionalGrouping conditionalGrouping : this.conditionalGroupings) {
          Boolean hasInnerMatch = conditionalGrouping == calcItem;
          if(hasInnerMatch && conditionalGrouping.isOrConditional()) {
            matches = true;
          } else if(conditionalGrouping.isOrConditional() == false) {
            matches = matches && hasInnerMatch;
          }
        }
      }
      return matches;
    }

    private void createConditions(SObjectType calcItemSObjectType) {
      List<String> splitWhere = this.getSoqlWhereClauses(this.whereClause, calcItemSObjectType);
      try {
        for (String splitWhereClause : splitWhere) {
          Boolean isOrConditional = isOrConditional(this.whereClause, splitWhereClause);
          List<WhereFieldCondition> conditions = this.createConditionsFromString(splitWhereClause, calcItemSObjectType);
          if (isOrConditional) {
            this.conditionalGroupings.add(new OrConditionalGrouping(conditions));
          } else {
            this.conditionalGroupings.add(new AndConditionalGrouping(conditions));
          }
        }
      } catch (Exception ex) {
        this.logError(ex);
        throw new IllegalArgumentException('Where clause entered incorrectly: ' + whereClause);
      }
    }

    private List<String> getSoqlWhereClauses(String whereClause, SObjectType calcItemSObjectType) {
      List<String> splitWheres = whereClause.split('( and | AND | OR | or )');
      this.reconstructImproperlySplitClauses(splitWheres);
      this.recurseForNestedConditionals(splitwheres, calcItemSObjectType);

      return splitWheres;
    }

    private void reconstructImproperlySplitClauses(List<String> splitWheres) {
      // shocker - strings can have the criteria keywords IN them. reconstitute the strings that have been incorrectly split
      for (Integer index = splitWheres.size() - 1; index >= 0; index--) {
        String splitWhereClause = splitWheres[index];
        // we have to assume that the only place where this could happen is at the back of the string
        if (splitWhereClause.endsWith('\'') && splitWhereClause.indexOf('\'') == splitWhereClause.length() - 1 && index > 0) {
          try {
            String nextString = splitWheres[index - 1];
            String foundCriteria = whereClause.substring(whereClause.indexOf(nextString) + nextString.length(), whereClause.indexOf(splitWhereClause)).trim();
            splitWheres[index - 1] = (nextString + ' ' + foundCriteria + ' ' + splitWhereClause);
            splitWheres.remove(index);
          } catch (Exception ex) {
            this.logError(ex);
          }
        }
      }
    }

    private void recurseForNestedConditionals(List<String> splitWheres, SObjectType calcItemSObjectType) {
      // this time we can't iterate through the list in reverse simply because there are
      // multiple instances where a parathenses is perfectly valid to have at the end of the where clause;
      // any IN-based condition, for example, would end with a paranthetical list of Ids/Strings
      // on the other hand, there's only one way there would be parantheses at the beginning of the statement -
      // if it was a nested conditional
      for (Integer index = 0; index < splitWheres.size(); index++) {
        String potentialNestedConditional = splitWheres[index].trim();
        Integer originalMatchIndex = index;
        Integer openParansRange = potentialNestedConditional.indexOf('(');
        if (openParansRange == 0) {
          // remove the parans now
          potentialNestedConditional = potentialNestedConditional.substring(1, potentialNestedConditional.length() - 1);
          // iterate through the rest of the list, stopping at the end of the parantheses
          for (Integer innerIndex = index + 1; innerIndex < splitWheres.size(); innerIndex++) {
            String innerMatch = splitWheres[innerIndex].trim();
            // remove the blanks afterwards!
            splitWheres[innerIndex] = '';
            if (innerMatch.endsWith(')')) {
              Integer startingPoint = this.whereClause.indexOf(potentialNestedConditional);
              Integer endingPoint = this.whereClause.indexOf(innerMatch) + (innerMatch.length() - 1);
              potentialNestedConditional = this.whereClause.substring(startingPoint, endingPoint);
              break;
            }
          }
          // we'll remove these blanks in a second
          splitWheres[originalMatchIndex] = '';

          List<WhereFieldCondition> conditions = new List<WhereFieldCondition>();
          Boolean isAnInnerOrCondition = false;
          List<String> innerWhereClauses = this.getSoqlWhereClauses(potentialNestedConditional, calcItemSObjectType);
          for(String innerWhere : innerWhereClauses) {
            isAnInnerOrCondition = isAnInnerOrCondition || this.isOrConditional(potentialNestedConditional, innerWhere);
            conditions.addAll(this.createConditionsFromString(innerWhere, calcItemSObjectType));
          }

          if (isAnInnerOrCondition) {
            this.conditionalGroupings.add(new OrConditionalGrouping(conditions));
          } else {
            this.conditionalGroupings.add(new AndConditionalGrouping(conditions));
          }
        }
      }
      for (Integer reverseIndex = splitWheres.size() - 1; reverseIndex >= 0; reverseIndex--) {
        String potentialWhereClause = splitWheres[reverseIndex];
        if (String.isBlank(potentialWhereClause)) {
          splitWheres.remove(reverseIndex);
        }
      }
    }

    private Boolean isOrConditional(String fullString, String conditionalStatement) {
      Boolean isOr = false;
      Boolean isFirstConditional = fullString.indexOf(conditionalStatement) == 0;
      if(isFirstConditional) {
        return isOr;
      }
      Integer whereWeAreInTheFullString = fullString.indexOf(conditionalStatement) + conditionalStatement.length();
      Integer clauseStartingIndex = whereWeAreInTheFullString - (conditionalStatement.length() + 5);
      if (clauseStartingIndex > 0) {
        isOr = fullString.substring(clauseStartingIndex, whereWeAreInTheFullString).containsIgnoreCase('or');
      } else {
        // do nothing, but with PMD happy
        isOr = false;
      }
      return isOr;
    }

    private List<WhereFieldCondition> createConditionsFromString(String whereClause, SObjectType calcItemSObjectType) {
      List<WhereFieldCondition> conditions = new List<WhereFieldCondition>();
      whereClause = whereClause.trim();
      String fieldName = whereClause.substring(0, whereClause.indexOf(' '));
      whereClause = whereClause.replace(fieldName, '').trim();
      String criteria = whereClause.substring(0, whereClause.indexOf(' ')).trim();
      String value = whereClause.replace(criteria, '').trim().replaceAll('\'', '').trim();
      if(value.startsWith('(') && value.contains(',') == false) {
        value = value.substring(1, value.length());
      } else if(value.endsWith(')') && value.contains(',') == false) {
        value = value.substring(0, value.length() - 1);
      }
      if (value.startsWith('(') && value.endsWith(')')) {
        List<String> values = value.substring(1, value.length() - 1).split(',');
        conditions.add(new WhereFieldCondition(fieldName, criteria, values, calcItemSObjectType));
      } else {
        conditions.add(new WhereFieldCondition(fieldName, criteria, value, calcItemSObjectType));
      }
      return conditions;
    }

    private void logError(Exception ex) {
      System.debug(LoggingLevel.ERROR, 'RollupEvaluator: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
    }
  }

  private abstract class ConditionalGrouping {
    protected final List<WhereFieldCondition> innerConditions;
    public ConditionalGrouping(List<WhereFieldCondition> innerConditions) {
      this.innerConditions = innerConditions;
    }

    public Boolean equals(Object calcItem) {
      return this.conditionallyEquals(calcItem);
    }

    public virtual Boolean isOrConditional() {
      return false;
    }

    protected abstract Boolean conditionallyEquals(Object calcItem);
  }

  private class OrConditionalGrouping extends ConditionalGrouping {
    public OrConditionalGrouping(List<WhereFieldCondition> innerConditions) {
      super(innerConditions);
    }

    public override Boolean isOrConditional() {
      return true;
    }

    protected override Boolean conditionallyEquals(Object calcItem) {
      Boolean isEqual = false;
      for (WhereFieldCondition innerCondition : this.innerConditions) {
        isEqual = innerCondition.equals(calcItem);
        if (isEqual) {
          break;
        }
      }
      return isEqual;
    }
  }

  private class AndConditionalGrouping extends ConditionalGrouping {
    public AndConditionalGrouping(List<WhereFieldCondition> innerConditions) {
      super(innerConditions);
    }
    protected override Boolean conditionallyEquals(Object calcItem) {
      Boolean isEqual = true;
      for (WhereFieldCondition condition : this.innerConditions) {
        isEqual = condition.equals(calcItem);
        if (isEqual == false) {
          break;
        }
      }
      return isEqual;
    }
  }

  private class WhereFieldCondition {
    private final SObjectType sObjectType;
    private final String fieldName;
    private final String criteria;
    private final List<String> originalValues;
    private final List<String> values;
    private final Boolean hasValues;

    public WhereFieldCondition(String fieldName, String criteria, String value, SObjectType sObjectType) {
      this(fieldName, criteria, new List<String>{ value }, sObjectType);
    }
    public WhereFieldCondition(String fieldName, String criteria, List<String> values, SObjectType sObjectType) {
      this.fieldName = fieldName;
      this.criteria = criteria;
      this.originalValues = values;
      this.sObjectType = sObjectType;
      this.values = new List<String>();

      for (String val : values) {
        if (String.isNotBlank(val)) {
          if(this.hasValues == null) {
            this.hasValues = true;
          }
          this.values.add(val.trim().replace('%', ''));
        }
      }
    }

    public Boolean equals(Object o) {
      SObject item = (SObject) o;
      Boolean isEqual = true;

      String storedValue = String.valueOf(this.getFieldValue(item, this.fieldName, this.sObjectType));
      switch on this.criteria {
        when '=' {
          isEqual = this.values.contains(storedValue) || this.hasValues == null && String.isBlank(storedValue);
        }
        when '!=' {
          isEqual = this.values.contains(storedValue) == false || (String.isBlank(storedValue) && this.hasValues);
        }
        when 'like', '!like' {
          // like/not like have to be handled separately because it's the storedValue
          // that gets tested against, not the other way around
          Boolean containsCriteria = false;
          if(storedValue == null) {
            return false;
          }
          for (String val : this.values) {
            containsCriteria = containsCriteria || storedValue.contains(val);
          }
          isEqual = this.criteria == 'like' ? containsCriteria : containsCriteria == false;
        }
        // then there's this whole paradigm; it really shouldn't be possible to have multiple values for either
        // greater than / less than routes, but we test for it first just to be triple-sure
        when '>', '>=' {
          if (this.values.size() != 1) {
            throw new IllegalArgumentException('Comparison not valid with multiple arguments: ' + JSON.serialize(this.values));
          } else if(storedValue == null) {
            return false;
          }

          return this.criteria.endsWith('=') ? storedValue >= this.values[0] : storedValue > this.values[0];
        }
        when '<', '<=' {
          if (this.values.size() != 1) {
            throw new IllegalArgumentException('Comparison not valid with multiple arguments: ' + JSON.serialize(this.values));
          } else if(storedValue == null) {
            return false;
          }

          return this.criteria.endsWith('=') ? storedValue <= this.values[0] : storedValue < this.values[0];
        }
      }
      return isEqual;
    }

    public override String toString() {
      String baseString = this.fieldName + ' ' + this.criteria + ' ';
      baseString += this.originalValues.size() == 1 ? '' : '(';
      for (String val : this.originalValues) {
        String escapedVal = '\'' + val + '\'';
        baseString += this.originalValues.indexOf(val) > 0 ? ', ' + escapedVal : escapedVal;
      }
      baseString += this.originalValues.size() == 1 ? '' : ')';
      return baseString;
    }

    private Object getFieldValue(SObject item, String fieldPath, SObjectType sObjectType) {
      // handle compound fields separately
      if (fieldPath.contains('.') && sObjectType.getDescribe().fields.getMap().containsKey(fieldPath) == false) {
        return this.getRelationshipFieldValue(item, fieldPath, sObjectType);
      }
      return item == null ? '' : item.get(fieldPath);
    }

    private Object getRelationshipFieldValue(SObject item, String fieldPath, SObjectType sObjectType) {
      List<String> fieldNameParts = fieldPath.split(RELATIONSHIP_FIELD_DELIMITER);
      // here, we pop fields off the front of the list because for tertiary+ object relationships (eg Owner.Profile.Name)
      // we need to recurse till the value itself can be captured
      String relationshipName = fieldNameParts.remove(0).trim();
      String originalName = relationshipName;

      if (relationshipName.contains('__r')) {
        relationshipName = relationshipName.replace('__r', '__c');
      } else {
        relationshipName += 'Id';
      }

      SObjectField fieldToken = sObjectType.getDescribe().fields.getMap().get(relationshipName);
      SObjectType parentSObjectType;
      if (fieldToken.getDescribe().isNamePointing()) {
        Id fieldValue = (Id) item.get(relationshipName);
        parentSObjectType = fieldValue.getSobjectType();
      } else {
        // there's only ever one item in the list for non-polymorphic fields
        parentSObjectType = fieldToken.getDescribe().getReferenceTo()[0];
      }
      SObject parentSObject = item.getSObject(originalName);
      if (fieldNameParts.isEmpty() == false) {
        return this.getFieldValue(parentSObject, String.join(fieldNameParts, '.'), parentSObjectType);
      } else {
        return parentSObject.get(originalName);
      }
    }
  }
}
