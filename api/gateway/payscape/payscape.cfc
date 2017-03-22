<!---

	Copyright 2012 WRIS Web Services - Adam M. Euans (http://www.wris.com/)
	
	PayScape Implementation Guide:
	
	Licensed under the Apache License, Version 2.0 (the "License"); you 
	may not use this file except in compliance with the License. You may 
	obtain a copy of the License at:
	 
		http://www.apache.org/licenses/LICENSE-2.0
		 
	Unless required by applicable law or agreed to in writing, software 
	distributed under the License is distributed on an "AS IS" BASIS, 
	WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
	See the License for the specific language governing permissions and 
	limitations under the License.
--->
<cfcomponent displayname="PayScape Interface" extends="cfpayment.api.gateway.base" hint="PayScape Gateway" output="false">

	<cfscript>
		variables.cfpayment.GATEWAY_NAME = "PayScape";
		variables.cfpayment.GATEWAY_VERSION = "2007.06";
		
		// The test URL requires a separate developer transKey and login
		variables.cfpayment.GATEWAY_TEST_URL = "https://secure.payscapegateway.com/api/transact.php";
		variables.cfpayment.GATEWAY_LIVE_URL = "https://secure.payscapegateway.com/api/transact.php";
		//variables.cfpayment.GATEWAY_responseDelimeter = "|"; // For x_delim_char - Any valid character overrides merchant interface setting if defined.		
		
		structInsert(variables, "payscape", structNew());
		structInsert(variables.payscape, "respReasonCodes", structNew());
		structInsert(variables.payscape, "errorReasonCodes", structNew());
		
		addResponseReasonCodes(); // Sets up the response code lookup struct.		
	</cfscript>

	<!--- ------------------------------------------------------------------------------
		  process wrapper with gateway/transaction error handling
		  ------------------------------------------------------------------------- --->
	<cffunction name="process" output="false" access="private" returntype="any">
		<cfargument name="payload" type="struct" required="true" />
		<cfargument name="options" type="struct" required="false" default="#structNew()#" />
		<cfset var local = {}>
		<cfsetting requesttimeout="#max(getCurrentRequestTimeout(), getTimeout() + 10)#" />
		
		<cfscript>
			//fold in any optional data
			structAppend(arguments.payload, filterOptions(arguments.options), true);
			if (!structKeyExists(arguments.payload, 'ipaddress')) arguments.payload.ipaddress = cgi.remote_addr;
			
			// Configure the gateway environment variables.
			structInsert(arguments.payload, "PASSWORD", getPassword(), "yes");
			structInsert(arguments.payload, "USERNAME", getUsername(), "yes");

			// Setup Response Data
			local.responseData = { 
				 Status 	 = getService().getStatusPending()
				,StatusCode  = ""
				,Result 	 = ""
				,Message 	 = ""
				,RequestData = {}
				,TestMode 	 = getTestMode()
			};

			local.responseData.result = doHttpCall(
				 url 		 = getGatewayURL() & '?' & formatPayload(arguments.payload)
				,method 	 = 'GET'
				,timeout 	 = getTimeout()
			);
			
			local.responseData.statusCode = reReplace(local.responseData.result.statusCode, "[^0-9]", "", "ALL");	
						
			if (isStruct(local.responseData.result) AND structKeyExists(local.responseData.result, "fileContent"))
				local.responseData.result = local.responseData.result.fileContent;
			else 
				local.responseData.result = getService().getStatusUnknown();	
			
			local.response = createResponse(argumentCollection=local.responseData);
			local.response.setParsedResult(parseResponse(local.response.getResult()));
			
			if(structKeyExists(local.response.getParsedResult(), 'transactionID'))
				local.response.setTransactionID(local.response.getParsedResult().transactionID);

			if(structKeyExists(local.response.getParsedResult(), 'authCode'))
				local.response.setAuthorization(local.response.getParsedResult().authCode);
			//writedump(var=local.response.getParsedResult().cvvResponse, abort=true);
			if(structKeyExists(local.response.getParsedResult(), 'cvvResponse'))
				local.response.setCvvCode(trim(local.response.getParsedResult().cvvResponse));
		
			if(structKeyExists(local.response.getParsedResult(), 'avsResponse'))
				local.response.setAVSCode(trim(local.response.getParsedResult().avsResponse));
								
			local.responseCode = local.response.getParsedResult().response_code;			
			local.response.setMessage(getResponseReasonCode(local.responseCode).respReasonText);			

			if (listFind('100', local.responseCode)) 	
				local.response.setStatus(getService().getStatusSuccessful());
			else 
				local.response.setStatus(getService().getStatusDeclined());			
			
			structInsert(local.response.getParsedResult(), "Reference", getResponseReasonCode(local.responseCode), "yes");
			structInsert(local.response.getParsedResult(), "Additional", "Gateway=" & getGatewayName(), "yes"); // Reply with the gateway used.
//writedump(var=local.response.getMemento(), abort=true);
			return local.response;
		</cfscript>
	</cffunction>

	<!--- ------------------------------------------------------------------------------
		  PUBLIC METHODS
		  ------------------------------------------------------------------------- --->
	<cffunction name="purchase" output="false" access="public" returntype="any" hint="Authorize + Capture in one step">
		<cfargument name="money" type="any" required="true" />
		<cfargument name="account" type="any" required="true" />
		<cfargument name="options" type="struct" required="false" default="#structNew()#" />
		<cfscript>
			var post = structNew();
		
			// set general values
			structInsert(post, "AMOUNT", arguments.money.getAmount(), "yes");
			structInsert(post, "TYPE", "Sale", "yes");

			switch (lcase(listLast(getMetaData(arguments.account).fullname, "."))) {
				case "creditcard": {
					// copy in name and customer details
					post = addCustomer(post = post, account = arguments.account, options = arguments.options);
					post = addCreditCard(post = post, account = arguments.account, options = arguments.options);
					break;
				}
				default: {
					throw("The account type #lcase(listLast(getMetaData(arguments.account).fullname, "."))# is not supported by this gateway.", "", "cfpayment.InvalidAccount");
					break;
				}			
			}

			return process(payload = post, options = arguments.options);
		</cfscript>
	</cffunction>

	
	<cffunction name="authorize" output="false" access="public" returntype="any" hint="Authorize (only) a credit card">
		<cfargument name="money" type="any" required="true" />
		<cfargument name="account" type="any" required="true" />
		<cfargument name="options" type="struct" required="false" default="#structNew()#" />
		<cfscript>
			var post = structNew();
		
			// set general values
			structInsert(post, "AMOUNT", arguments.money.getAmount(), "yes");
			structInsert(post, "TYPE", "auth", "yes");

			switch (lcase(listLast(getMetaData(arguments.account).fullname, "."))) {
				case "creditcard": {
					// copy in name and customer details
					post = addCustomer(post = post, account = arguments.account, options = arguments.options);
					post = addCreditCard(post = post, account = arguments.account, options = arguments.options);
					break;
				}
				default: {
					throw("The account type #lcase(listLast(getMetaData(arguments.account).fullname, "."))# is not supported by this gateway.", "", "cfpayment.InvalidAccount");
					break;
				}			
			}

			return process(payload = post, options = arguments.options);
		</cfscript>
	</cffunction>


	<cffunction name="capture" output="false" access="public" returntype="any" hint="Capture a prior authorization - set it to be settled.">
		<cfargument name="money" type="any" required="false" />
		<cfargument name="transactionid" type="any" required="true" />
		<cfargument name="options" type="struct" required="false" default="#structNew()#" />
		<cfscript>
			var post = structNew();
		
			// set general values
			if (structKeyExists(arguments, 'money') AND isObject(arguments.money)) 
				structInsert(post, "AMOUNT", arguments.money.getAmount(), "yes");
			structInsert(post, "TYPE", "Capture", "yes");
			structInsert(post, "TRANSACTIONID", trim(arguments.transactionid), "yes");

			return process(payload = post, options = arguments.options);
		</cfscript>
	</cffunction>
	
	
	<cffunction name="credit" output="false" access="public" returntype="any" hint="Refund all or part of a previous transaction">
		<cfargument name="money" type="any" required="true" />
		<cfargument name="transactionid" type="any" required="false" />
		<cfargument name="account" type="any" required="false" />
		<cfargument name="options" type="struct" required="false" default="#structNew()#" />
		<cfscript>
			var post = structNew();
		
			// set required values
			if (structKeyExists(arguments, 'money') AND isObject(arguments.money)) 
				structInsert(post, "AMOUNT", arguments.money.getAmount(), "yes");
			structInsert(post, "TYPE", "Refund", "yes");
			structInsert(post, "TRANSACTIONID", trim(arguments.transactionid), "yes");

			switch (lcase(listLast(getMetaData(arguments.account).fullname, "."))) {
				case "creditcard": {
					// copy in name and customer details
					post = addCustomer(post = post, account = arguments.account, options = arguments.options);
					post = addCreditCard(post = post, account = arguments.account, options = arguments.options);
					break;
				}
				default: {
					throw("The account type #lcase(listLast(getMetaData(arguments.account).fullname, "."))# is not supported by this gateway.", "", "cfpayment.InvalidAccount");
					break;
				}			
			}

			return process(payload = post, options = arguments.options);
		</cfscript>
	</cffunction>

	<cffunction name="void" output="false" access="public" returntype="any" hint="Cancel a pending transaction - must be called on an un-settled transaction.">
		<cfargument name="transactionid" type="any" required="true" />
		<cfargument name="options" type="struct" default="#structNew()#" />
		<cfscript>
			var post = structNew();
		
			// set required values
			structInsert(post, "TYPE", "Void", "yes");
			structInsert(post, "TRANSACTIONID", trim(arguments.transactionid), "yes");

			return process(payload = post, options = arguments.options);
		</cfscript>
	</cffunction>
	
	<cffunction name="refund" output="false" access="public" returntype="any" hint="Transaction refunds will reverse a previously settled transaction. If the transaction has not been settled, it must be voided instead of refunded.">
		<cfargument name="transactionid" type="any" required="true" />
		<cfargument name="money" type="any" required="false" />
		<cfargument name="options" type="struct" default="#structNew()#" />
		<cfscript>
			var post = structNew();
		
			// set required values
			if (structKeyExists(arguments, 'money') AND isObject(arguments.money))
				structInsert(post, "AMOUNT", arguments.money.getAmount(), "yes");
				
			structInsert(post, "TYPE", "Refund", "yes");
			structInsert(post, "TRANSACTIONID", trim(arguments.transactionid), "yes");

			return process(payload = post, options = arguments.options);
		</cfscript>
	</cffunction>
	
	<!--- ------------------------------------------------------------------------------
		  CUSTOM GETTERS/SETTERS
		  ------------------------------------------------------------------------- --->


	<!--- ------------------------------------------------------------------------------
		  PRIVATE HELPER METHODS
		  ------------------------------------------------------------------------- --->
	<cffunction name="addCustomer" output="false" access="private" returntype="any" hint="Add customer contact details to the request object">
		<cfargument name="post" type="struct" required="true" />
		<cfargument name="account" type="any" required="true" />
		<cfargument name="options" type="struct" required="true" />		
		<cfscript>
			structAppend(arguments.post, arguments.account.getMemento(), false);
			if (len(arguments.account.getRegion()))
				structInsert(arguments.post, 'STATE', arguments.account.getRegion());
				
			if (len(arguments.account.getPostalCode())) 
				structInsert(arguments.post, "ZIP", arguments.account.getPostalCode()); // ZIP code for the customer's address
			
			return arguments.post;
		</cfscript>
	</cffunction>

	<cffunction name="addCreditCard" output="false" access="private" returntype="any" hint="Add payment source fields to the request object">
		<cfargument name="post" type="struct" required="true" />
		<cfargument name="account" type="any" required="true" />
		<cfargument name="options" type="struct" required="true" />
		<cfscript>
			structInsert(arguments.post, "CCNUMBER", arguments.account.getAccount()); // credit card number
			structInsert(arguments.post, "CCEXP", dateFormat(createDate(arguments.account.getYear(), arguments.account.getMonth(), 1), "mmyy")); // credit card expiration month
			structInsert(arguments.post, "CVV", arguments.account.getVerificationValue()); // credit card Security Code

			return arguments.post;
		</cfscript>
	</cffunction>

	<cffunction name="throw" output="true" access="public" hint="Script version of CF tag: CFTHROW">
		<cfargument name="message" required="no" default="" />
		<cfargument name="detail" required="no" default="" />
		<cfargument name="type" required="no" />
		<cfif not isSimpleValue(arguments.message)>
			<cfsavecontent variable="arguments.message">
				<cfdump var="#arguments.message#" />
			</cfsavecontent>
		</cfif>
		<cfif not isSimpleValue(arguments.detail)>
			<cfsavecontent variable="arguments.detail">
				<cfdump var="#arguments.detail#" />
			</cfsavecontent>
		</cfif>
		<cfif structKeyExists(arguments, "type")>
			<cfthrow message="#arguments.message#" detail="#arguments.detail#" type="#arguments.type#" />
		<cfelse>
			<cfthrow message="#arguments.message#" detail="#arguments.detail#" />
		</cfif>
	</cffunction>

	<cfscript>
		// Parse the delimited gateway response.
		function formatPayload(payload) {
			var rtnPayload = '';
			
			if(isStruct(payload)){
				for(i in payload){
					rtnPayload &= lCase(i) & '=' & trim(payload[i]) & '&';
				}
				rtnPayload = reReplace(rtnPayload, '\&$', '');
			}else{
				return payload;	
			}
					
			return rtnPayload;	
		}
		
		// Parse the delimited gateway response.
		function parseResponse(gatewayResponse) {
			var results = structNew();
			
			// Use Java's split because we have empty list elements which CF doesn't natively handle.
			var response = JavaCast('string', arguments.gatewayResponse).split("\&");
			for(local.item=1; local.item<=arrayLen(response); local.item++){
				if (listLen(response[local.item], '=') GT 1)
					results[listFirst(response[local.item], '=')] = listLast(response[local.item], '=');
				else
					results[listFirst(response[local.item], '=')] = '';	
			}
					
			return results;	
		}

		// Helper function for parseResponse();
		function insertResult(results, response, listPosition, FieldName, fieldKey, defaultValue) {
			var value = arguments.defaultValue;
	
			if (arrayLen(arguments.response) GTE arguments.listPosition AND len(arguments.response[arguments.listPosition]))
				value = arguments.response[arguments.listPosition];
	
			if (len(arguments.fieldKey)) {
				if (structKeyExists(arguments.results, arguments.fieldKey))
					structInsert(arguments.results, "#arguments.fieldKey##arguments.listPosition#", value);
				else
					structInsert(arguments.results, "#arguments.fieldKey#", value);
			}
			else if (len(arguments.FieldName)) {
				if (structKeyExists(arguments.results, arguments.FieldName))
					structInsert(arguments.results, "#arguments.FieldName##arguments.listPosition#", value);
				else
					structInsert(arguments.results, "#arguments.FieldName#", value);
			}
			return arguments.results;
		}
		
		// Helper function for addResponseReasonCodes();
		function addResponseReasonCode(respCode, respReasonText, notes) {
			var resp = structNew();
			structInsert(resp, "respCode", arguments.respCode);
			structInsert(resp, "respReasonText", arguments.respReasonText);
			structInsert(resp, "notes", arguments.notes);

			structInsert(variables.payscape.respReasonCodes, arguments.respCode, resp, "no");
			
			return variables.payscape.respReasonCodes;
		}
		
		function getResponseReasonCode(respCode) {
			var resp = structNew();
			if (structKeyExists(variables.payscape.respReasonCodes, arguments.respCode)) {
				resp = variables.payscape.respReasonCodes[arguments.respCode];
			}
			else {
				structInsert(resp, "respCode", "");
				structInsert(resp, "respReasonText", "");
				structInsert(resp, "notes", "");				
			}
			return resp;
		}
			
		function filterOptions(options){
			var local = {};
			local.validList = 'account_holder_type,account_type,address1,address2,amount,ccexp,ccnumber,checkaba,checkaccount,checkname,city,company,country,cvv,descriptor,descriptor_phone,dup_seconds,email,fax,firstname,ipaddress,lastname,orderdescription,orderid,original,password,payment,phone,ponumber,processor_id,sec_code,shipping,shipping_address1,shipping_address2,shipping_carrier,shipping_city,shipping_company,shipping_country,shipping_email,shipping_firstname,shipping_lastname,shipping_state,shipping_zip,state,tax,tracking_number,transactionid,type,username,validation,variable,zip';
			
			return structExtract(arguments.options, local.validList);
		}
		
		// Called when this CFC is created to setup the response code lookup structure.
		function addResponseReasonCodes() {
			addResponseReasonCode("100", "Transaction was Approved", "Transaction was Approved");
			addResponseReasonCode("200", "Transaction was Declined by Processor", "Transaction was Declined by Processor");
			addResponseReasonCode("201", "Do Not Honor", "Do Not Honor");
			addResponseReasonCode("202", "Insufficient Funds", "Insufficient Funds");
			addResponseReasonCode("203", "Over Limit", "Over Limit");
			addResponseReasonCode("204", "Transaction not allowed", "Transaction not allowed");
			addResponseReasonCode("220", "Incorrect Payment Data", "Incorrect Payment Data");
			addResponseReasonCode("221", "No Such Card Issuer", "No Such Card Issuer");
			addResponseReasonCode("222", "No Card Number on file with Issuer", "No Card Number on file with Issuer");
			addResponseReasonCode("223", "Expired Card", "Expired Card");
			addResponseReasonCode("224", "Invalid Expiration Date", "Invalid Expiration Date");
			addResponseReasonCode("225", "Invalid Card Security Code", "Invalid Card Security Code");
			addResponseReasonCode("240", "Call Issuer for Further Information", "Call Issuer for Further Information");
			addResponseReasonCode("250", "Pick Up Card", "Pick Up Card");
			addResponseReasonCode("251", "Lost Card", "Lost Card");
			addResponseReasonCode("252", "Stolen Card", "Stolen Card");
			addResponseReasonCode("253", "Fraudulant Card", "Fraudulant Card");
			addResponseReasonCode("260", "Declined with further Instructions Available (see response text)", "Declined with further Instructions Available (see response text)");
			addResponseReasonCode("261", "Declined - Stop All Recurring Payments", "Declined - Stop All Recurring Payments");
			addResponseReasonCode("262", "Declined - Stop this Recurring Program", "Declined - Stop this Recurring Program");
			addResponseReasonCode("263", "Declined - Update Cardholder Data Available", "Declined - Update Cardholder Data Available");
			addResponseReasonCode("264", "Declined - Retry in a few days", "Declined - Retry in a few days");
			addResponseReasonCode("300", "Transaction was Rejected by Gateway", "Transaction was Rejected by Gateway");
			addResponseReasonCode("400", "Transaction Error Returned by Processor", "Transaction Error Returned by Processor");
			addResponseReasonCode("410", "Invalid Merchant Configuration", "Invalid Merchant Configuration");
			addResponseReasonCode("411", "Merchant Account is Inactive", "Merchant Account is Inactive");
			addResponseReasonCode("420", "Communication Error", "Communication Error");
			addResponseReasonCode("421", "Communication Error with Issuer", "Communication Error with Issuer");
			addResponseReasonCode("430", "Duplicate Transaction at Processor", "Duplicate Transaction at Processor");
			addResponseReasonCode("440", "Processor Format Error", "Processor Format Error");
			addResponseReasonCode("441", "Invalid Transaction Information", "Invalid Transaction Information");
			addResponseReasonCode("460", "Processor Feature not Available", "Processor Feature not Available");
			addResponseReasonCode("461", "Unsupported Card Type", "Unsupported Card Type"); 
		}
	</cfscript>
	
<!--- [ Private Struct Function: StructExtract() ] --->
<cffunction name="StructExtract" access="private" output="false" returntype="struct">
    <cfargument name="struct" type="struct" required="true"/>
    <cfargument name="keyList" type="string" required="true"/>
	<cfset var local = structNew()>
    <cfset local.returnStruct = StructNew() />

    <cfloop list="#uCase(arguments.keyList)#" index="local.key">
        <cfif structKeyExists(arguments.struct, trim(local.key))>
			<cfset local.returnStruct[trim(local.key)] = arguments.struct[trim(local.key)] />
		</cfif>
    </cfloop>

    <cfreturn local.returnStruct />
</cffunction>
</cfcomponent>