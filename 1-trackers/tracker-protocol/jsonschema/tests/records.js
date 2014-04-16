define([
	'intern!object',
	'intern/chai!assert',
	'intern/dojo/node!z-schema',
	'intern/dojo/node!../events/ad_impression',
	'intern/dojo/node!../events/ad_click',
	'intern/dojo/node!../events/ad_conversion',
	'intern/dojo/node!../events/link_click',
	'intern/dojo/node!../events/screen_view',
	'intern/dojo/node!./resources/ad_impression',
	'intern/dojo/node!./resources/ad_click',
	'intern/dojo/node!./resources/ad_conversion',
	'intern/dojo/node!./resources/link_click',
	'intern/dojo/node!./resources/screen_view'
], function(registerSuite, assert, ZSchema,
			adImpressionSchema, adClickSchema, adConversionSchema, linkClickSchema, screenViewSchema,
			adImpressionJsons,  adClickJsons,  adConversionJsons,  linkClickJsons,  screenViewJsons) {

	var validator = new ZSchema({sync: true}),
		testArray = [
			[adImpressionSchema, adImpressionJsons],
			[adClickSchema, adClickJsons],
			[adConversionSchema, adConversionJsons],
			[linkClickSchema, linkClickJsons],
			[screenViewSchema, screenViewJsons]
		],
		j;

	function testSchema(schema, json) { console.log(typeof schema, typeof json)
		registerSuite({
			name: json.name + ' schema validation',

			'Valid JSONs should pass validation': function() {
				var validJsons = json.valid,
					valid,
					i;
				for (i = 0; i < validJsons.length; i++) {
					valid = validator.validate(validJsons[i], schema);
					assert.strictEqual(valid, true, 'Valid JSON #' + (i+1) + ' should be validated');
				}	
			},

			'Invalid JSONs should fail validation': function() {
				var invalidJsons = json.invalid,
					valid,
					i;
				for (i = 0; i < invalidJsons.length; i++) {
					valid = validator.validate(invalidJsons[i], schema);
					assert.strictEqual(valid, false, 'Invalid JSON #' + (i+1) + ' should be invalidated');
				}
			}
		})
	}

	for (var j = 0; j < testArray.length; j++) {
		testSchema(testArray[j][0], testArray[j][1])
	}

});
