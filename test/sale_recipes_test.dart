import 'package:flutter_test/flutter_test.dart';
import 'package:hinkredience/core/best_buy.dart';
import 'package:hinkredience/core/sale_recipes.dart';
import 'package:hinkredience/data/recipe.dart';

Recipe recipe(String title, List<String> ingredients) => Recipe(
  id: title,
  title: title,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  ingredients: [
    for (final (i, name) in ingredients.indexed)
      Ingredient(id: '$title-$i', name: name),
  ],
);

PriceOffer offer(
  String chain,
  String product,
  double price, {
  double? regular,
  bool verified = true,
  DateTime? validTo,
}) => PriceOffer(
  id: '$chain-$product-$price',
  chain: chain,
  product: product,
  price: price,
  regularPrice: regular,
  validTo: validTo ?? DateTime(2026, 11, 22),
  sourceUrl: 'https://www.$chain.cz/letak',
  verified: verified,
);

void main() {
  final today = DateTime(2026, 11, 17);
  final recipes = [
    recipe('Kuře na paprice', ['Kuřecí stehna', 'Smetana', 'Paprika', 'Sůl']),
    recipe('Řízky s bramborem', ['Kuřecí prsní řízky', 'Brambory', 'Vejce']),
    recipe('Palačinky', ['Hladká mouka', 'Mléko', 'Vejce', 'Sůl']),
  ];

  test('recepty seřazené podle surovin v akci a úspory', () {
    final r = recipesFromSales(recipes, [
      offer('lidl', 'Kuřecí prsní řízky chlazené', 129.9, regular: 179.9),
      offer('albert', 'Vejce M 10 ks', 39.9, regular: 54.9),
      offer('penny', 'Vejce L 10 ks', 44.9),
      offer('tesco', 'Smetana ke šlehání 31 %', 24.9, regular: 34.9),
    ], today);
    expect(r.map((x) => x.recipe.title), [
      'Řízky s bramborem',
      'Palačinky',
      'Kuře na paprice',
    ], reason: 'stejně surovin v akci → větší úspora napřed');
    final rizky = r.first;
    expect(rizky.hits.map((h) => h.offer.price), [129.9, 39.9]);
    expect(rizky.savings, closeTo(65, 0.001));
    expect(rizky.chains, {'lidl', 'albert'});
    expect(rizky.ingredientCount, 3);
    expect(r[2].ingredientCount, 3, reason: 'sůl se nepočítá');
  });

  test('neověřené a prošlé akce se nepočítají', () {
    expect(
      recipesFromSales(recipes, [
        offer('lidl', 'Vejce', 30, verified: false),
        offer('albert', 'Vejce', 30, validTo: DateTime(2026, 11, 16)),
      ], today),
      isEmpty,
    );
    expect(
      recipesFromSales(recipes, [
        offer('albert', 'Vejce', 30, validTo: DateTime(2026, 11, 17)),
      ], today),
      hasLength(2),
      reason: 'akce platí i v poslední den',
    );
  });

  test('máslový chléb není máslo', () {
    final r = recipesFromSales(
      [
        recipe('Bábovka', ['Máslo', 'Cukr krupice']),
      ],
      [offer('penny', 'Chléb toustový máslový', 23.9)],
      today,
    );
    expect(r, isEmpty);
  });

  test('co hledat: nejčastější suroviny bez základů', () {
    expect(ingredientsWorthSearching(recipes), [
      'Vejce',
      'Brambory',
      'Hladká mouka',
      'Kuřecí prsní řízky',
      'Kuřecí stehna',
      'Mléko',
      'Paprika',
      'Smetana',
    ]);
    expect(ingredientsWorthSearching(recipes, limit: 1), ['Vejce']);
  });
}
